//
//  PipelineRunner.swift
//  MacON
//
//  One local CI pipeline: poll a branch, build each new commit, report status.
//

import Foundation
import Combine

@MainActor
public final class PipelineRunner: ObservableObject, Identifiable {

    @Published public var config: PipelineConfig
    @Published public private(set) var isWatching = false
    @Published public private(set) var isBuilding = false
    @Published public private(set) var buildState: BuildState = .idle
    @Published public private(set) var log: [LogLine] = []
    @Published public private(set) var lastPoll: Date?
    /// Past runs (newest first), loaded from disk.
    @Published public private(set) var history: [RunSummary] = []

    /// Supplies a client for the given provider (nil if its credentials aren't set).
    public var makeClient: (GitProviderKind) -> (any GitProvider)? = { _ in nil }
    /// Supplies the pool's global secrets (shared by all pipelines).
    public var loadGlobalSecrets: () -> [String: String] = { [:] }

    public var id: UUID { config.id }

    /// The client for this pipeline's configured provider.
    private func client() -> (any GitProvider)? { makeClient(config.provider) }

    private var lastBuiltSHA: String?
    private var lastBuiltPRSHAs: [Int: String] = [:]
    private var prBaselineEstablished = false
    private var currentPR: GitPullRequest?
    private var pollTask: Task<Void, Never>?
    /// Per-build cancellation + current-process handle, shared with the executor.
    /// `@unchecked Sendable` so the nonisolated executor can read/write it safely enough
    /// for our purposes (single writer for the process, a bool flag for cancel).
    final class ExecutionControl: @unchecked Sendable {
        var cancelled = false
        var currentProcess: Process?
        func cancel() { cancelled = true; currentProcess?.terminate() }
    }
    private var control = ExecutionControl()
    private var webhookServer: WebhookServer?
    private var nextLineID = 0
    private let maxLines = 4000
    private let statusKey = "macon-ci"

    // Per-build capture for saving to history.
    private var capturing = false
    private var buildLines: [LogLine] = []
    private var runStartedAt: Date?

    public init(config: PipelineConfig) {
        self.config = config
        history = RunStore.loadIndex(config.id)
        // Remember the last commit we actually built, so re-launching and
        // watching doesn't rebuild a commit we've already handled.
        lastBuiltSHA = history.first?.shaFull
    }

    /// Load a past run's log lines (off the main actor).
    public func lines(for runID: UUID) async -> [LogLine] {
        let pid = config.id
        return await Task.detached { RunStore.loadLines(pid, runID) }.value
    }

    // MARK: - Watching

    public func startWatching() {
        guard !isWatching else { return }
        guard client() != nil else {
            let what = config.provider == .github ? "GitHub token" : "Bitbucket account (email + API token)"
            appendLine("⚠︎ Set your \(what) in Settings first.")
            return
        }
        guard !config.workspace.isEmpty, !config.repoSlug.isEmpty else {
            appendLine("⚠︎ Set workspace / repo in this pipeline's settings.")
            return
        }
        isWatching = true
        prBaselineEstablished = false
        let target: String
        switch config.watchMode {
        case .branch:
            target = "branch \(config.branch)"
        case .pullRequests:
            let f = config.prTargetBranch.trimmingCharacters(in: .whitespaces)
            target = f.isEmpty ? "open PRs" : "open PRs → \(f)"
        }

        switch config.triggerMode {
        case .polling:
            appendLine("👀 Polling \(config.workspace)/\(config.repoSlug) — \(target) "
                       + "(every \(config.pollSeconds)s).")
            pollTask = Task { @MainActor in await self.pollLoop() }
        case .webhook:
            startWebhookServer(target: target)
        }
    }

    public func stopWatching() {
        isWatching = false
        pollTask?.cancel()
        pollTask = nil
        webhookServer?.stop()
        webhookServer = nil
        appendLine("🛑 Stopped watching.")
    }

    // MARK: - Webhook trigger

    private func startWebhookServer(target: String) {
        let port = UInt16(clamping: config.webhookPort)
        let server = WebhookServer(
            port: port,
            onLog: { [weak self] line in Task { @MainActor in self?.appendLine(line) } },
            onEvent: { [weak self] event in Task { @MainActor in self?.handleWebhook(event) } })
        server.start()
        webhookServer = server
        appendLine("🪝 Webhook listening on :\(port) — \(target). "
                   + "Point Bitbucket at http://<this-mac>:\(port)/ (repo settings → Webhooks).")
    }

    /// Decide whether an incoming webhook event should build, then build it.
    private func handleWebhook(_ event: WebhookEvent) {
        guard isWatching else { return }
        lastPoll = Date()

        // If the payload names a repo, ignore events for a different one.
        let expected = "\(config.workspace)/\(config.repoSlug)"
        if !event.repoFullName.isEmpty && event.repoFullName != expected { return }

        if isBuilding {
            appendLine("🔔 Event received while building — ignoring (will catch the next).")
            return
        }

        switch config.watchMode {
        case .branch:
            guard event.kind == .push, event.branch == config.branch else { return }
            guard event.commit != lastBuiltSHA else { return }
            appendLine("🔔 Webhook: push \(event.commit.prefix(8)) on \(config.branch).")
            isBuilding = true
            control = ExecutionControl()
            Task { @MainActor in await self.build(sha: event.commit) }

        case .pullRequests:
            guard event.kind == .pullRequest, let prID = event.prID else { return }
            let filter = config.prTargetBranch.trimmingCharacters(in: .whitespaces)
            if !filter.isEmpty, event.prDestBranch != filter { return }
            guard lastBuiltPRSHAs[prID] != event.commit else { return }
            let pr = GitPullRequest(
                id: prID, title: event.prTitle ?? "PR #\(prID)",
                sourceBranch: event.prSourceBranch ?? event.branch,
                sourceCommit: event.commit,
                destBranch: event.prDestBranch ?? "")
            lastBuiltPRSHAs[prID] = event.commit
            appendLine("🔔 Webhook: PR #\(prID) “\(pr.title)” → \(event.commit.prefix(8)).")
            isBuilding = true
            control = ExecutionControl()
            Task { @MainActor in await self.build(sha: event.commit, pr: pr) }
        }
    }

    private func pollLoop() async {
        while isWatching && !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(for: .seconds(max(5, config.pollSeconds)))
        }
    }

    private func pollOnce() async {
        guard let client = client() else { return }
        switch config.watchMode {
        case .branch:       await pollBranch(client)
        case .pullRequests: await pollPRs(client)
        }
    }

    private func pollBranch(_ client: any GitProvider) async {
        do {
            let sha = try await client.latestCommit(
                workspace: config.workspace, repo: config.repoSlug, branch: config.branch)
            lastPoll = Date()
            // First time we see this branch: record head as baseline, don't build.
            if lastBuiltSHA == nil {
                lastBuiltSHA = sha
                appendLine("👀 Baseline at \(sha.prefix(8)) — will build new commits from here.")
                return
            }
            if sha != lastBuiltSHA && !isBuilding {
                appendLine("🔔 New commit \(sha.prefix(8)) on \(config.branch).")
                isBuilding = true
                control = ExecutionControl()
                await build(sha: sha)
            }
        } catch {
            appendLine("✗ Poll failed: \(error.localizedDescription)")
        }
    }

    private func pollPRs(_ client: any GitProvider) async {
        guard !isBuilding else { return }
        do {
            var prs = try await client.listOpenPullRequests(
                workspace: config.workspace, repo: config.repoSlug)
            lastPoll = Date()
            let filter = config.prTargetBranch.trimmingCharacters(in: .whitespaces)
            if !filter.isEmpty { prs = prs.filter { $0.destBranch == filter } }

            // First poll: baseline all open PRs (don't build), then react to changes.
            if !prBaselineEstablished {
                for pr in prs { lastBuiltPRSHAs[pr.id] = pr.sourceCommit }
                prBaselineEstablished = true
                appendLine("👀 Baseline: \(prs.count) open PR(s) — will build new PR commits from here.")
                return
            }
            for pr in prs {
                if control.cancelled || isBuilding { break }
                if lastBuiltPRSHAs[pr.id] != pr.sourceCommit {
                    appendLine("🔔 PR #\(pr.id) “\(pr.title)” → \(pr.sourceCommit.prefix(8)).")
                    lastBuiltPRSHAs[pr.id] = pr.sourceCommit
                    isBuilding = true
                    control = ExecutionControl()
                    await build(sha: pr.sourceCommit, pr: pr)
                }
            }
        } catch {
            appendLine("✗ PR poll failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Manual build

    /// Build the current head now, regardless of whether it's new.
    public func runNow() {
        guard !isBuilding else { return }
        guard let client = client() else {
            let what = config.provider == .github ? "GitHub token" : "Bitbucket account"
            appendLine("⚠︎ Set your \(what) in Settings first.")
            return
        }
        isBuilding = true          // immediate UI feedback (button → Stop)
        control = ExecutionControl()
        appendLine("⏳ Fetching head commit…")
        Task { @MainActor in
            do {
                let sha = try await client.latestCommit(
                    workspace: config.workspace, repo: config.repoSlug, branch: config.branch)
                if control.cancelled {
                    appendLine("⏹ Cancelled before build started.")
                    isBuilding = false
                    return
                }
                await build(sha: sha)
            } catch {
                appendLine("✗ Couldn't fetch head: \(error.localizedDescription)")
                isBuilding = false
            }
        }
    }

    // MARK: - Build

    // Callers set `isBuilding = true` (+ reset `cancelRequested`) before calling.
    private func build(sha: String, pr: GitPullRequest? = nil) async {
        currentPR = pr
        buildState = .running(sha: sha)
        runStartedAt = Date()
        buildLines = []
        capturing = true          // appendLine now also records into this run
        if let pr {
            appendLine("──────── PR #\(pr.id): \(pr.title) @ \(sha.prefix(8)) ────────")
        } else {
            appendLine("──────── build \(sha.prefix(8)) ────────")
        }

        let client = client()
        if config.postStatus {
            await post(client, sha: sha, state: .inProgress, desc: "Building on MacON")
        }

        let synced = await syncRepo(sha: sha)
        var code: Int32 = synced
        if synced == 0 && !control.cancelled {
            if let pipeline = await loadPipelineFile(in: config.workingDirectory) {
                appendLine("📄 Using \(config.pipelineFile)"
                           + (pipeline.name.map { " — \($0)" } ?? ""))
                let ctrl = control
                let options = PipelineExecutor.Options(
                    workingDirectory: config.workingDirectory,
                    workflowName: config.workflow,
                    branch: pr == nil ? config.branch : nil,
                    pullRequestDestBranch: pr?.destBranch,
                    env: externalEnv(sha: sha),
                    shouldCancel: { ctrl.cancelled },
                    onProcess: { ctrl.currentProcess = $0 })
                code = await PipelineExecutor.run(pipeline, options: options,
                                                  onLine: { [weak self] line in
                    Task { @MainActor in self?.appendLine(line) }
                })
            } else {
                code = await shellStep(config.buildCommand)
            }
        }

        lastBuiltSHA = sha
        isBuilding = false

        let result: RunResult
        if control.cancelled {
            result = .cancelled
            buildState = .failed(sha: sha)
            appendLine("⏹ Build cancelled.")
            if config.postStatus { await post(client, sha: sha, state: .failed, desc: "Cancelled on MacON") }
        } else if code == 0 {
            result = .succeeded
            buildState = .succeeded(sha: sha)
            appendLine("✅ Build passed.")
            if config.postStatus { await post(client, sha: sha, state: .successful, desc: "Passed on MacON") }
        } else {
            result = .failed
            buildState = .failed(sha: sha)
            appendLine("❌ Build failed (exit \(code)).")
            if config.postStatus { await post(client, sha: sha, state: .failed, desc: "Failed on MacON (exit \(code))") }
        }

        // Persist this run to history.
        capturing = false
        let summary = RunSummary(id: UUID(), shaFull: sha,
                                 startedAt: runStartedAt ?? Date(), finishedAt: Date(),
                                 result: result)
        let run = PipelineRun(summary: summary, lines: buildLines)
        let pid = config.id
        let updated = await Task.detached { RunStore.save(run, pipelineID: pid) }.value
        history = updated
        currentPR = nil
    }

    /// Stop the in-flight build: kills the running shell and skips remaining steps.
    public func cancelBuild() {
        guard isBuilding else { return }
        control.cancel()
        appendLine("⏹ Cancelling build…")
    }

    // MARK: - Repo-defined pipeline (macon.yml)

    /// Read the pipeline file from the checkout, if present. YAML is converted to
    /// JSON via Ruby (available wherever fastlane runs) so we need no YAML library.
    private func loadPipelineFile(in dir: String) async -> MaconPipeline? {
        let file = config.pipelineFile.trimmingCharacters(in: .whitespaces)
        guard !file.isEmpty else { return nil }
        let path = "\(dir)/\(file)"
        let pipeline = await Task.detached { MaconPipelineLoader.load(atPath: path) }.value
        if pipeline == nil, FileManager.default.fileExists(atPath: path) {
            appendLine("⚠︎ Found \(file) but couldn't parse it — using the build command instead.")
        }
        return pipeline
    }

    /// External env passed to the executor: MACON_*/CI + provider-native vars +
    /// PR vars, merged with secrets (secrets win). MACON_WORKFLOW is set by the executor.
    private func externalEnv(sha: String) -> [String: String] {
        let branch = currentPR?.sourceBranch ?? config.branch
        var env: [String: String] = [
            "MACON_COMMIT": sha,
            "MACON_COMMIT_SHORT": String(sha.prefix(8)),
            "MACON_BRANCH": branch,
            "MACON_REPO": "\(config.workspace)/\(config.repoSlug)",
            "MACON_BUILD_NUMBER": "\(history.count + 1)",
            "MACON_PROVIDER": config.provider.rawValue,
            "CI": "true",
        ]
        if let pr = currentPR {
            env["MACON_PR_ID"] = "\(pr.id)"
            env["MACON_PR_TITLE"] = pr.title
            env["MACON_PR_SOURCE"] = pr.sourceBranch
            env["MACON_PR_DEST"] = pr.destBranch
        }
        // Provider-native vars (BITBUCKET_* / GITHUB_*) for Danger, fastlane, etc.
        if let client = client() {
            for (k, v) in client.stepEnv(workspace: config.workspace, repo: config.repoSlug,
                                         sha: sha, branch: branch, pr: currentPR,
                                         buildNumber: history.count + 1) {
                env[k] = v
            }
        }
        // Secrets (global + per-pipeline) win over everything.
        for (k, v) in loadSecrets() { env[k] = v }
        return env
    }

    /// Secret env values: global (shared) overlaid with this pipeline's own.
    private func loadSecrets() -> [String: String] {
        var out = loadGlobalSecrets()
        for key in config.secretKeys {
            let v = Keychain.get(account: "secret:\(config.id.uuidString):\(key)")
            if !v.isEmpty { out[key] = v }
        }
        return out
    }

    /// Clone (first run) or fetch + hard-checkout the target commit.
    private func syncRepo(sha: String) async -> Int32 {
        let dir = config.workingDirectory
        guard let client = client() else {
            appendLine("✗ No credentials for \(config.provider.label).")
            return 1
        }
        let (authedURL, safeURL) = client.cloneURL(workspace: config.workspace, repo: config.repoSlug)

        try? FileManager.default.createDirectory(
            atPath: (dir as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)

        let script = """
        set -e
        if [ -d "\(dir)/.git" ]; then
          git -C "\(dir)" remote set-url origin "\(authedURL)"
          git -C "\(dir)" fetch --all --prune
        else
          rm -rf "\(dir)"
          git clone "\(authedURL)" "\(dir)"
        fi
        git -C "\(dir)" checkout -f "\(sha)"
        git -C "\(dir)" reset --hard "\(sha)"
        """
        appendLine("$ " + script.replacingOccurrences(of: authedURL, with: safeURL))
        return await shell(script, cwd: NSHomeDirectory())
    }

    /// Fallback build command (no macon.yml) — echoes then runs in the checkout.
    private func shellStep(_ command: String) async -> Int32 {
        appendLine("$ \(command)")
        return await shell(command, cwd: config.workingDirectory, extraEnv: externalEnv(sha: lastBuiltSHA ?? ""))
    }

    /// Run a shell command via the shared Shell, streaming lines into the log.
    private func shell(_ command: String, cwd: String, extraEnv: [String: String] = [:]) async -> Int32 {
        let ctrl = control
        return await Shell.run(command, cwd: cwd, extraEnv: extraEnv,
                               onProcess: { ctrl.currentProcess = $0 },
                               onLine: { [weak self] line in
            Task { @MainActor in self?.appendLine(line) }
        })
    }

    private func post(_ client: (any GitProvider)?, sha: String,
                      state: BuildStatus, desc: String) async {
        guard let client else { return }
        do {
            try await client.postBuildStatus(
                workspace: config.workspace, repo: config.repoSlug, sha: sha,
                key: statusKey, state: state, name: config.name, description: desc)
        } catch {
            appendLine("⚠︎ Status post failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Logging

    private func appendLine(_ text: String) {
        let line = LogLine(id: nextLineID, text: text, date: Date())
        log.append(line)
        nextLineID += 1
        if log.count > maxLines { log.removeFirst(log.count - maxLines) }
        if capturing { buildLines.append(line) }
    }
    public func clearLog() { log.removeAll() }
    public var logPlainText: String { log.map(\.text).joined(separator: "\n") }
}
