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

    /// Supplies a client from the pool's shared credentials (nil if not set).
    public var makeClient: () -> BitbucketClient? = { nil }
    /// Supplies the pool's global secrets (shared by all pipelines).
    public var loadGlobalSecrets: () -> [String: String] = { [:] }

    public var id: UUID { config.id }

    private var lastBuiltSHA: String?
    private var lastBuiltPRSHAs: [Int: String] = [:]
    private var prBaselineEstablished = false
    private var currentPR: BitbucketClient.PullRequest?
    private var pollTask: Task<Void, Never>?
    private var currentProcess: Process?
    private var cancelRequested = false
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
        guard makeClient() != nil else {
            appendLine("⚠︎ Set your Bitbucket account in Settings first (email + API token).")
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
        appendLine("👀 Watching \(config.workspace)/\(config.repoSlug) — \(target) "
                   + "(every \(config.pollSeconds)s).")
        pollTask = Task { @MainActor in await self.pollLoop() }
    }

    public func stopWatching() {
        isWatching = false
        pollTask?.cancel()
        pollTask = nil
        appendLine("🛑 Stopped watching.")
    }

    private func pollLoop() async {
        while isWatching && !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(for: .seconds(max(5, config.pollSeconds)))
        }
    }

    private func pollOnce() async {
        guard let client = makeClient() else { return }
        switch config.watchMode {
        case .branch:       await pollBranch(client)
        case .pullRequests: await pollPRs(client)
        }
    }

    private func pollBranch(_ client: BitbucketClient) async {
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
                cancelRequested = false
                await build(sha: sha)
            }
        } catch {
            appendLine("✗ Poll failed: \(error.localizedDescription)")
        }
    }

    private func pollPRs(_ client: BitbucketClient) async {
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
                if cancelRequested || isBuilding { break }
                if lastBuiltPRSHAs[pr.id] != pr.sourceCommit {
                    appendLine("🔔 PR #\(pr.id) “\(pr.title)” → \(pr.sourceCommit.prefix(8)).")
                    lastBuiltPRSHAs[pr.id] = pr.sourceCommit
                    isBuilding = true
                    cancelRequested = false
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
        guard let client = makeClient() else {
            appendLine("⚠︎ Set your Bitbucket account in Settings first.")
            return
        }
        isBuilding = true          // immediate UI feedback (button → Stop)
        cancelRequested = false
        appendLine("⏳ Fetching head commit…")
        Task { @MainActor in
            do {
                let sha = try await client.latestCommit(
                    workspace: config.workspace, repo: config.repoSlug, branch: config.branch)
                if cancelRequested {
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
    private func build(sha: String, pr: BitbucketClient.PullRequest? = nil) async {
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

        let client = makeClient()
        if config.postStatus {
            await post(client, sha: sha, state: .inProgress, desc: "Building on MacON")
        }

        let synced = await syncRepo(sha: sha)
        var code: Int32 = synced
        if synced == 0 && !cancelRequested {
            if let pipeline = await loadPipelineFile(in: config.workingDirectory) {
                appendLine("📄 Using \(config.pipelineFile)"
                           + (pipeline.name.map { " — \($0)" } ?? ""))
                code = await runPipeline(pipeline, sha: sha)
            } else {
                code = await runShell(config.buildCommand, cwd: config.workingDirectory)
            }
        }

        lastBuiltSHA = sha
        isBuilding = false
        currentProcess = nil

        let result: RunResult
        if cancelRequested {
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
        cancelRequested = true
        appendLine("⏹ Cancelling build…")
        currentProcess?.terminate()
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

    private struct ResolvedStep { let step: MaconStep; let env: [String: String] }

    /// Resolve the workflow to run, expand before/after composition, then execute
    /// with Bitrise-like semantics (run_if conditions, always_run, fail-fast).
    private func runPipeline(_ pipeline: MaconPipeline, sha: String) async -> Int32 {
        let appEnv = pipeline.env ?? [:]
        var resolved: [ResolvedStep] = []
        var workflowName = "default"

        if let name = chooseWorkflow(pipeline) {
            workflowName = name
            appendLine("▶︎ Workflow: \(name)")
            var visiting = Set<String>()
            expand(name, pipeline, appEnv: appEnv, visiting: &visiting, into: &resolved)
            if resolved.isEmpty {
                appendLine("✗ Workflow “\(name)” has no steps."); return 1
            }
        } else if let steps = pipeline.steps, !steps.isEmpty {
            resolved = steps.map { ResolvedStep(step: $0, env: appEnv) }
        } else {
            appendLine("✗ No workflow matched branch “\(config.branch)” and no top-level steps.")
            return 1
        }

        let builtins = builtinEnv(sha: sha, workflow: workflowName)
        let secrets = loadSecrets()
        var failed = false
        var firstFailCode: Int32 = 0

        for r in resolved {
            if cancelRequested { return firstFailCode == 0 ? 1 : firstFailCode }
            appendLine("--- Step: \(r.step.name) ---")

            if failed && !(r.step.always_run ?? false) {
                appendLine("↷ Skipped (a previous step failed).")
                continue
            }
            var env = r.env
            for (k, v) in builtins { env[k] = v }
            for (k, v) in secrets { env[k] = v }   // user secrets win

            if let cond = r.step.run_if?.trimmingCharacters(in: .whitespacesAndNewlines), !cond.isEmpty {
                let condCode = await runShell(cond, cwd: config.workingDirectory, echo: false, extraEnv: env)
                if condCode != 0 { appendLine("↷ Skipped (run_if not met)."); continue }
            }

            let code = await runShell(r.step.script, cwd: config.workingDirectory, echo: false, extraEnv: env)
            if code != 0 {
                appendLine("✗ Step “\(r.step.name)” failed (exit \(code)).")
                if !failed { failed = true; firstFailCode = code }
            }
        }
        return failed ? firstFailCode : 0
    }

    /// Pick the workflow: explicit config override, else match branch to triggers,
    /// else a single/`default` workflow.
    private func chooseWorkflow(_ pipeline: MaconPipeline) -> String? {
        let explicit = config.workflow.trimmingCharacters(in: .whitespaces)
        if !explicit.isEmpty { return explicit }
        if let triggers = pipeline.triggers {
            if let pr = currentPR {
                // PR build: match pull_request triggers against the destination branch.
                for t in triggers {
                    if let p = t.pull_request, p == "*" || globMatch(p, pr.destBranch) {
                        return t.workflow
                    }
                }
            } else {
                for t in triggers {
                    if let b = t.branch, globMatch(b, config.branch) { return t.workflow }
                }
            }
        }
        if pipeline.workflows?["default"] != nil { return "default" }
        if let wfs = pipeline.workflows, wfs.count == 1 { return wfs.keys.first }
        return nil
    }

    /// Expand a workflow into a flat step list: before_run → own steps → after_run.
    /// `visiting` guards against cycles and double-runs.
    private func expand(_ name: String, _ pipeline: MaconPipeline,
                        appEnv: [String: String], visiting: inout Set<String>,
                        into out: inout [ResolvedStep]) {
        guard !visiting.contains(name) else { return }
        guard let wf = pipeline.workflows?[name] else {
            appendLine("⚠︎ Referenced workflow “\(name)” not found."); return
        }
        visiting.insert(name)
        for b in wf.before_run ?? [] { expand(b, pipeline, appEnv: appEnv, visiting: &visiting, into: &out) }
        var env = appEnv
        for (k, v) in wf.env ?? [:] { env[k] = v }
        for s in wf.steps ?? [] { out.append(ResolvedStep(step: s, env: env)) }
        for a in wf.after_run ?? [] { expand(a, pipeline, appEnv: appEnv, visiting: &visiting, into: &out) }
    }

    /// Secret env values: global (shared) overlaid with this pipeline's own,
    /// so a per-pipeline secret overrides a global one of the same name.
    private func loadSecrets() -> [String: String] {
        var out = loadGlobalSecrets()
        for key in config.secretKeys {
            let v = Keychain.get(account: "secret:\(config.id.uuidString):\(key)")
            if !v.isEmpty { out[key] = v }
        }
        return out
    }

    private func builtinEnv(sha: String, workflow: String) -> [String: String] {
        var env: [String: String] = [
            "MACON_COMMIT": sha,
            "MACON_COMMIT_SHORT": String(sha.prefix(8)),
            "MACON_BRANCH": config.branch,
            "MACON_REPO": "\(config.workspace)/\(config.repoSlug)",
            "MACON_WORKFLOW": workflow,
            "MACON_BUILD_NUMBER": "\(history.count + 1)",
            "CI": "true",
        ]
        // Expose the account so steps (e.g. Danger, git) can authenticate.
        if let client = makeClient() {
            env["BITBUCKET_EMAIL"] = client.email
            env["BITBUCKET_API_TOKEN"] = client.token
        }
        // PR context — also set the env Danger's Bitbucket Cloud provider reads,
        // so `danger ci` detects the PR and can post comments.
        if let pr = currentPR {
            env["MACON_BRANCH"] = pr.sourceBranch
            env["MACON_PR_ID"] = "\(pr.id)"
            env["MACON_PR_TITLE"] = pr.title
            env["MACON_PR_SOURCE"] = pr.sourceBranch
            env["MACON_PR_DEST"] = pr.destBranch
            env["BITBUCKET_PR_ID"] = "\(pr.id)"
            env["BITBUCKET_REPO_FULL_NAME"] = "\(config.workspace)/\(config.repoSlug)"
            env["BITBUCKET_REPO_OWNER"] = config.workspace
            env["BITBUCKET_REPO_SLUG"] = config.repoSlug
            env["BITBUCKET_BRANCH"] = pr.sourceBranch
            env["BITBUCKET_COMMIT"] = sha
            env["BITBUCKET_BUILD_NUMBER"] = "\(history.count + 1)"
        }
        return env
    }

    private func globMatch(_ pattern: String, _ value: String) -> Bool {
        let rx = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return value.range(of: "^\(rx)$", options: .regularExpression) != nil
    }

    /// Clone (first run) or fetch + hard-checkout the target commit.
    private func syncRepo(sha: String) async -> Int32 {
        let dir = config.workingDirectory
        let token = makeClient() != nil ? currentToken() : ""
        // Token-authenticated HTTPS URL (matches Bitbucket's app-token git auth).
        let authedURL = "https://x-bitbucket-api-token-auth:\(token)@bitbucket.org/"
            + "\(config.workspace)/\(config.repoSlug).git"
        let safeURL = "https://x-bitbucket-api-token-auth:***@bitbucket.org/"
            + "\(config.workspace)/\(config.repoSlug).git"

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
        let display = script.replacingOccurrences(of: authedURL, with: safeURL)
        return await runShell(script, cwd: NSHomeDirectory(), display: display)
    }

    private func post(_ client: BitbucketClient?, sha: String,
                      state: BitbucketClient.Status, desc: String) async {
        guard let client else { return }
        do {
            try await client.postBuildStatus(
                workspace: config.workspace, repo: config.repoSlug, sha: sha,
                key: statusKey, state: state, name: config.name, description: desc)
        } catch {
            appendLine("⚠︎ Status post failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Shell

    private func currentToken() -> String { makeClient().map { $0.token } ?? "" }

    private func runShell(_ command: String, cwd: String, display: String? = nil,
                          echo: Bool = true, extraEnv: [String: String] = [:]) async -> Int32 {
        if echo { appendLine("$ \(display ?? command)") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd.isEmpty ? NSHomeDirectory() : cwd)
        if !extraEnv.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { env[k] = v }
            proc.environment = env
        }

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.ingest(s) }
        }

        let code = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            proc.terminationHandler = { p in
                let handle = pipe.fileHandleForReading
                handle.readabilityHandler = nil
                let rest = handle.readDataToEndOfFile()
                if !rest.isEmpty, let s = String(data: rest, encoding: .utf8) {
                    Task { @MainActor in self.ingest(s) }
                }
                cont.resume(returning: p.terminationStatus)
            }
            do {
                currentProcess = proc
                try proc.run()
            } catch {
                Task { @MainActor in self.appendLine("✗ \(error.localizedDescription)") }
                cont.resume(returning: -1)
            }
        }
        return code
    }

    // MARK: - Logging

    private func ingest(_ chunk: String) {
        for raw in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if !line.isEmpty { appendLine(line) }
        }
    }
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
