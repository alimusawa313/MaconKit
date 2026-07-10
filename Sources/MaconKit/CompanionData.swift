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
        CompanionPipelinesDTO(pipelines: runnersProvider().map { dto($0) },
                              managed: pool != nil)
    }

    /// Prometheus text exposition for `GET /metrics`.
    public func metricsText() -> String {
        let runners = runnersProvider()
        var out = """
        # HELP macon_up 1 while the runner is serving.
        # TYPE macon_up gauge
        macon_up 1
        # HELP macon_pipelines_total Configured pipelines.
        # TYPE macon_pipelines_total gauge
        macon_pipelines_total \(runners.count)
        # HELP macon_pipelines_watching Pipelines with an active watcher.
        # TYPE macon_pipelines_watching gauge
        macon_pipelines_watching \(runners.filter(\.isWatching).count)
        # HELP macon_builds_running Builds in progress right now.
        # TYPE macon_builds_running gauge
        macon_builds_running \(runners.filter(\.isBuilding).count)

        """
        out += """
        # HELP macon_pipeline_watching Whether this pipeline's watcher is running.
        # TYPE macon_pipeline_watching gauge
        # HELP macon_pipeline_building Whether this pipeline is building.
        # TYPE macon_pipeline_building gauge
        # HELP macon_builds_total Finished builds by result (persisted history).
        # TYPE macon_builds_total counter
        # HELP macon_build_duration_seconds Duration of the most recent finished build.
        # TYPE macon_build_duration_seconds gauge

        """
        for r in runners {
            let label = Self.promEscape(r.config.name)
            out += "macon_pipeline_watching{pipeline=\"\(label)\"} \(r.isWatching ? 1 : 0)\n"
            out += "macon_pipeline_building{pipeline=\"\(label)\"} \(r.isBuilding ? 1 : 0)\n"
            var counts: [String: Int] = [:]
            for run in r.history { counts[CompanionJSON.status(run.result), default: 0] += 1 }
            for (result, n) in counts.sorted(by: { $0.key < $1.key }) {
                out += "macon_builds_total{pipeline=\"\(label)\",result=\"\(result)\"} \(n)\n"
            }
            if let last = r.history.first {
                out += "macon_build_duration_seconds{pipeline=\"\(label)\"} "
                     + String(format: "%.1f", last.duration) + "\n"
            }
        }
        return out
    }

    private static func promEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
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
