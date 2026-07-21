//
//  RunnerAgent.swift
//  MacON
//
//  Owns the child-process lifecycle of ONE runner in the pool.
//

import Foundation
import Combine

public struct LogLine: Identifiable, Sendable, Codable {
    public let id: Int
    public let text: String
    public let date: Date
    public init(id: Int, text: String, date: Date) {
        self.id = id; self.text = text; self.date = date
    }
}

public enum RunnerState: Equatable {
    case stopped
    case starting
    case running
    case crashed(code: Int32)

    public var label: String {
        switch self {
        case .stopped:  return "Stopped"
        case .starting: return "Starting…"
        case .running:  return "Running"
        case .crashed(let c): return "Crashed (exit \(c))"
        }
    }
    public var isActive: Bool { self == .running || self == .starting }
}

@MainActor
public final class RunnerAgent: ObservableObject, Identifiable {

    @Published public var instance: RunnerInstance
    @Published public private(set) var state: RunnerState = .stopped
    @Published public private(set) var log: [LogLine] = []
    @Published public private(set) var startedAt: Date?
    @Published public var isCleaning = false

    /// Kept in sync by the pool so on-stop cleanup honours current settings.
    public var cleanupSettings: CleanupSettings

    public var id: UUID { instance.id }

    private var process: Process?
    private var manualStop = false
    private var nextLineID = 0
    private let maxLines = 2000

    public init(instance: RunnerInstance, cleanupSettings: CleanupSettings) {
        self.instance = instance
        self.cleanupSettings = cleanupSettings
    }

    // MARK: - Control

    public func start() {
        guard !state.isActive else { return }
        let command = instance.startCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            appendLine("⚠︎ No start command. Paste the runner command from Bitbucket "
                       + "(Repository settings → Runners) in this runner's settings.")
            return
        }

        let workDir = instance.workingDirectory
        try? FileManager.default.createDirectory(
            atPath: workDir, withIntermediateDirectories: true)

        manualStop = false
        state = .starting
        startedAt = Date()
        appendLine("$ \(command)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command] // login shell → user PATH (java/xcodebuild)
        proc.currentDirectoryURL = URL(fileURLWithPath: workDir)

        // Point the runner at the newest JDK. The Bitbucket runner is built for a
        // recent Java; the system default is often too old (UnsupportedClassVersionError).
        var env = ProcessInfo.processInfo.environment
        if let jdk = JavaLocator.bestJDK() {
            env["JAVA_HOME"] = jdk.home
            env["PATH"] = "\(jdk.home)/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            appendLine("☕︎ Using Java \(jdk.version) at \(jdk.home)")
        } else {
            appendLine("⚠︎ No JDK found — install one (e.g. `brew install openjdk@25`).")
        }
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // EOF: clear the handler or the system re-invokes it forever.
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.ingest(chunk) }
        }
        proc.terminationHandler = { [weak self] p in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = p.terminationStatus
            Task { @MainActor in self?.handleTermination(status: status) }
        }

        do {
            try proc.run()
            process = proc
            state = .running
        } catch {
            state = .crashed(code: -1)
            appendLine("✗ Failed to launch: \(error.localizedDescription)")
        }
    }

    public func stop() {
        guard let proc = process, proc.isRunning else { state = .stopped; return }
        manualStop = true
        appendLine("⏹ Stopping runner…")
        proc.terminate()
    }

    // MARK: - Callbacks

    private func handleTermination(status: Int32) {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        startedAt = nil

        if manualStop {
            state = .stopped
            appendLine("⏹ Runner stopped.")
            if cleanupSettings.emptyWorkingDirOnStop { cleanWorkingDir() }
            return
        }

        state = .crashed(code: status)
        appendLine("✗ Runner exited unexpectedly (code \(status)).")
        if instance.restartOnCrash {
            appendLine("↻ Restarting in 5s…")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if !self.state.isActive && !self.manualStop { self.start() }
            }
        }
    }

    // MARK: - Cleanup (this runner's working dir only — safe alongside others)

    public func cleanWorkingDir() {
        guard !isCleaning, !state.isActive else { return }
        isCleaning = true
        appendLine("🧹 Emptying working directory…")
        let plan = cleanupSettings.workingDirPlan(for: instance.workingDirectory)
        Task { @MainActor in
            let report = await Cleaner.clean(plan)
            for line in report.lines { self.appendLine(line) }
            self.appendLine("🧹 Freed \(report.freedDescription).")
            self.isCleaning = false
        }
    }

    // MARK: - Logging

    private func ingest(_ chunk: String) {
        for raw in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if !line.isEmpty { appendLine(line) }
        }
    }

    private func appendLine(_ text: String) {
        log.append(LogLine(id: nextLineID, text: text, date: Date()))
        nextLineID += 1
        if log.count > maxLines { log.removeFirst(log.count - maxLines) }
    }

    public func clearLog() { log.removeAll() }
    public var logPlainText: String { log.map(\.text).joined(separator: "\n") }
}
