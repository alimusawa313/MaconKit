//
//  CompanionData.swift
//  MaconKit
//
//  Projects live PipelineRunner state into companion DTOs. MainActor-isolated
//  because it reads @Published runner state; the server awaits it from its own
//  queue.
//
//  Build IDs encode which runner and which run (separator "~" keeps the whole ID
//  in one URL path segment, so /builds/<id>/logs routes cleanly):
//    "<pipelineID>~live"    → the in-progress build (logs stream from runner.log)
//    "<pipelineID>~<runID>" → a finished run (logs loaded from RunStore)
//

import Foundation

@MainActor
public final class CompanionData {
    /// Read live so pipelines added/removed in the app are reflected immediately.
    private let runnersProvider: () -> [PipelineRunner]
    private let runnerName: String
    private let historyLimit = 20
    /// When present, paired devices may manage pipelines (add/edit/delete/watch)
    /// — the same operations the Mac app's UI performs on this pool.
    private weak var pool: PipelinePool?

    public init(runners: @escaping () -> [PipelineRunner], runnerName: String,
                pool: PipelinePool? = nil) {
        self.runnersProvider = runners
        self.runnerName = runnerName
        self.pool = pool
    }

    public func builds() -> CompanionBuildsDTO {
        var out: [CompanionBuildDTO] = []
        for r in runnersProvider() {
            let repo = "\(r.config.workspace)/\(r.config.repoSlug)"
            let pid = r.config.id.uuidString

            // The in-progress build, if any.
            if r.isBuilding, case .running(let sha) = r.buildState {
                out.append(CompanionBuildDTO(
                    id: "\(pid)~live", repo: repo, branch: r.config.branch,
                    commit: String(sha.prefix(8)), message: nil, status: "running",
                    startedAt: r.log.first?.date, finishedAt: nil,
                    currentStep: currentStep(r), steps: nil))
            }

            // Finished runs from history (newest first).
            for s in r.history.prefix(historyLimit) {
                out.append(CompanionBuildDTO(
                    id: "\(pid)~\(s.id.uuidString)", repo: repo, branch: r.config.branch,
                    commit: s.shaShort, message: nil, status: CompanionJSON.status(s.result),
                    startedAt: s.startedAt, finishedAt: s.finishedAt,
                    currentStep: nil, steps: nil))
            }
        }
        return CompanionBuildsDTO(runnerName: runnerName, builds: out)
    }

    public func build(id: String) -> CompanionBuildDTO? {
        builds().builds.first { $0.id == id }
    }

    /// Actions a paired device can take on a build.
    public enum BuildAction: String, Sendable { case cancel, rerun }

    /// Run a build action. `rerun` triggers a fresh run of the build's pipeline;
    /// `cancel` stops it if it's the one currently building. Returns false if the
    /// build can't be resolved or the action doesn't apply.
    @discardableResult
    public func perform(_ action: BuildAction, buildID: String) -> Bool {
        guard let (runner, _) = resolve(buildID) else { return false }
        switch action {
        case .cancel:
            guard runner.isBuilding else { return false }
            runner.cancelBuild()
        case .rerun:
            runner.runNow()
        }
        return true
    }

    /// Log lines for a build with `seq > afterSeq`, oldest first.
    public func linesSince(buildID: String, afterSeq: Int) async -> [CompanionLogDTO] {
        guard let (runner, part) = resolve(buildID) else { return [] }
        let lines: [LogLine]
        if part == "live" {
            lines = runner.log
        } else if let rid = UUID(uuidString: part) {
            lines = await runner.lines(for: rid)
        } else {
            return []
        }
        return lines.filter { $0.id > afterSeq }.map {
            CompanionLogDTO(seq: $0.id, text: $0.text.strippingANSI(),
                            level: CompanionJSON.level(for: $0.text), date: $0.date)
        }
    }

    // MARK: Pipeline management

    /// The configured pipelines with their live state.
    public func pipelines() -> CompanionPipelinesDTO {
        CompanionPipelinesDTO(pipelines: runnersProvider().map { dto($0) })
    }

    /// Create a pipeline from a submitted config. Fails without a pool.
    public func createPipeline(_ body: Data) -> Bool {
        guard let pool,
              let dto = try? CompanionJSON.decoder.decode(CompanionPipelineDTO.self, from: body)
        else { return false }
        let runner = pool.addPipeline()
        apply(dto, to: runner)
        pool.commitEdits()
        return true
    }

    /// Update an existing pipeline's config.
    public func updatePipeline(id: String, _ body: Data) -> Bool {
        guard let pool, let runner = runner(id),
              let dto = try? CompanionJSON.decoder.decode(CompanionPipelineDTO.self, from: body)
        else { return false }
        apply(dto, to: runner)
        pool.commitEdits()
        return true
    }

    /// Remove a pipeline (stops its watcher first, like the Mac app).
    public func deletePipeline(id: String) -> Bool {
        guard let pool, let runner = runner(id) else { return false }
        pool.remove(runner)
        return true
    }

    /// Start/stop watching (the runner toggle in the Mac app's footer).
    public func setWatching(id: String, on: Bool) -> Bool {
        guard let runner = runner(id) else { return false }
        if on { runner.startWatching() } else { runner.stopWatching() }
        return true
    }

    /// Build the current head immediately ("Run Now").
    public func runPipeline(id: String) -> Bool {
        guard let runner = runner(id) else { return false }
        runner.runNow()
        return true
    }

    /// Repo names under a workspace/owner, via the Mac's saved credentials.
    /// Nil when the provider/credentials can't serve the request.
    public func listRepos(provider: String, workspace: String) async -> [String]? {
        guard let kind = GitProviderKind(rawValue: provider),
              let client = pool?.makeClient(for: kind) else { return nil }
        return try? await client.listRepositories(workspace: workspace)
    }

    /// Branch names in a repo, via the Mac's saved credentials.
    public func listBranches(provider: String, workspace: String, repo: String) async -> [String]? {
        guard let kind = GitProviderKind(rawValue: provider),
              let client = pool?.makeClient(for: kind) else { return nil }
        return try? await client.listBranches(workspace: workspace, repo: repo)
    }

    private func runner(_ id: String) -> PipelineRunner? {
        runnersProvider().first { $0.config.id.uuidString == id }
    }

    private func dto(_ r: PipelineRunner) -> CompanionPipelineDTO {
        let c = r.config
        let state: String
        switch r.buildState {
        case .idle:      state = "idle"
        case .running:   state = "running"
        case .succeeded: state = "passed"
        case .failed:    state = "failed"
        }
        return CompanionPipelineDTO(
            id: c.id.uuidString, name: c.name, provider: c.provider.rawValue,
            workspace: c.workspace, repoSlug: c.repoSlug, branch: c.branch,
            watchMode: c.watchMode.rawValue, prTargetBranch: c.prTargetBranch,
            pipelineFile: c.pipelineFile, workflow: c.workflow, buildCommand: c.buildCommand,
            triggerMode: c.triggerMode.rawValue, pollSeconds: c.pollSeconds,
            webhookPort: c.webhookPort, buildTimeoutSeconds: c.buildTimeoutSeconds,
            postStatus: c.postStatus,
            isWatching: r.isWatching, isBuilding: r.isBuilding, state: state)
    }

    /// Copy the editable fields of a submitted config onto a runner (id and
    /// working directory stay server-owned).
    private func apply(_ dto: CompanionPipelineDTO, to runner: PipelineRunner) {
        var c = runner.config
        c.name = dto.name
        c.provider = GitProviderKind(rawValue: dto.provider) ?? c.provider
        c.workspace = dto.workspace
        c.repoSlug = dto.repoSlug
        c.branch = dto.branch
        c.watchMode = WatchMode(rawValue: dto.watchMode) ?? c.watchMode
        c.prTargetBranch = dto.prTargetBranch
        c.pipelineFile = dto.pipelineFile
        c.workflow = dto.workflow
        c.buildCommand = dto.buildCommand
        c.triggerMode = TriggerMode(rawValue: dto.triggerMode) ?? c.triggerMode
        c.pollSeconds = max(5, dto.pollSeconds)
        c.webhookPort = dto.webhookPort
        c.buildTimeoutSeconds = max(0, dto.buildTimeoutSeconds)
        c.postStatus = dto.postStatus
        runner.config = c
    }

    // MARK: Helpers

    private func resolve(_ buildID: String) -> (PipelineRunner, String)? {
        guard let sep = buildID.firstIndex(of: "~") else { return nil }
        let pid = String(buildID[..<sep])
        let part = String(buildID[buildID.index(after: sep)...])
        guard let runner = runnersProvider().first(where: { $0.config.id.uuidString == pid }) else { return nil }
        return (runner, part)
    }

    /// Best-effort current step from the last step/command marker in the live
    /// log — the same markers parseLogSections keys off.
    private func currentStep(_ r: PipelineRunner) -> String? {
        for line in r.log.reversed() {
            let t = line.text
            if let range = t.range(of: "--- Step: ") {
                return t[range.upperBound...].replacingOccurrences(of: "---", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            if t.hasPrefix("$ ") {
                return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
