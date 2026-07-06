//
//  RunStore.swift
//  MacON
//
//  Persists pipeline run history under Application Support/MacON/runs/<pipelineID>/.
//  A small index.json holds summaries (fast load); each run's log is a separate
//  file loaded on demand.
//

import Foundation

enum RunStore {
    static let keepLast = 50

    private static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("MacON/runs", isDirectory: true)
    }
    private static func dir(_ pid: UUID) -> URL {
        root.appendingPathComponent(pid.uuidString, isDirectory: true)
    }
    private static func indexURL(_ pid: UUID) -> URL {
        dir(pid).appendingPathComponent("index.json")
    }
    private static func runURL(_ pid: UUID, _ rid: UUID) -> URL {
        dir(pid).appendingPathComponent("\(rid.uuidString).json")
    }

    /// Summaries, newest first.
    static func loadIndex(_ pid: UUID) -> [RunSummary] {
        guard let data = try? Data(contentsOf: indexURL(pid)),
              let list = try? JSONDecoder().decode([RunSummary].self, from: data)
        else { return [] }
        return list
    }

    /// Save a run, prune to `keepLast`, return the updated (newest-first) index.
    @discardableResult
    static func save(_ run: PipelineRun, pipelineID pid: UUID) -> [RunSummary] {
        try? FileManager.default.createDirectory(at: dir(pid), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(run) {
            try? d.write(to: runURL(pid, run.summary.id))
        }
        var index = loadIndex(pid)
        index.insert(run.summary, at: 0)
        if index.count > keepLast {
            for old in index[keepLast...] {
                try? FileManager.default.removeItem(at: runURL(pid, old.id))
            }
            index = Array(index.prefix(keepLast))
        }
        if let d = try? JSONEncoder().encode(index) {
            try? d.write(to: indexURL(pid))
        }
        return index
    }

    static func loadLines(_ pid: UUID, _ rid: UUID) -> [LogLine] {
        guard let data = try? Data(contentsOf: runURL(pid, rid)),
              let run = try? JSONDecoder().decode(PipelineRun.self, from: data)
        else { return [] }
        return run.lines
    }

    static func deleteAll(_ pid: UUID) {
        try? FileManager.default.removeItem(at: dir(pid))
    }
}
