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

    public init(runners: @escaping () -> [PipelineRunner], runnerName: String) {
        self.runnersProvider = runners
        self.runnerName = runnerName
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
                            level: CompanionJSON.level(for: $0.text))
        }
    }

    // MARK: Helpers

    private func resolve(_ buildID: String) -> (PipelineRunner, String)? {
        guard let sep = buildID.firstIndex(of: "~") else { return nil }
        let pid = String(buildID[..<sep])
        let part = String(buildID[buildID.index(after: sep)...])
        guard let runner = runnersProvider().first(where: { $0.config.id.uuidString == pid }) else { return nil }
        return (runner, part)
    }

    /// Best-effort current step from the last "▸ …" marker in the live log.
    private func currentStep(_ r: PipelineRunner) -> String? {
        for line in r.log.reversed() where line.text.hasPrefix("▸") {
            return line.text.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
