//
//  Shell.swift
//  MaconKit
//
//  Streaming shell runner shared by the pipeline executor and the git sync step.
//

import Foundation

public enum Shell {
    /// Run `command` via `/bin/zsh -lc`, streaming stdout+stderr lines to `onLine`.
    /// `extraEnv` is merged over the current process environment. `onProcess`
    /// receives the spawned process (for cancellation). Returns the exit code.
    ///
    /// Note: `onLine` is invoked on a background thread; callers that need a
    /// specific actor (e.g. the GUI) should hop themselves.
    @discardableResult
    public static func run(
        _ command: String,
        cwd: String,
        extraEnv: [String: String] = [:],
        onProcess: (@Sendable (Process) -> Void)? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
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

        @Sendable func emit(_ chunk: String) {
            for raw in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                if !line.isEmpty { onLine(line) }
            }
        }

        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            // EOF: clear the handler or the system re-invokes it forever.
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            guard let s = String(data: d, encoding: .utf8) else { return }
            emit(s)
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            proc.terminationHandler = { p in
                let handle = pipe.fileHandleForReading
                handle.readabilityHandler = nil
                let rest = handle.readDataToEndOfFile()
                if !rest.isEmpty, let s = String(data: rest, encoding: .utf8) { emit(s) }
                cont.resume(returning: p.terminationStatus)
            }
            do {
                onProcess?(proc)
                try proc.run()
            } catch {
                onLine("✗ \(error.localizedDescription)")
                cont.resume(returning: -1)
            }
        }
    }
}
