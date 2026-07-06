//
//  Cleaner.swift
//  MacON
//
//  Reclaims disk used by CI builds. Runs off the main actor.
//

import Foundation

/// Immutable description of what to clean, computed from `RunnerConfig`.
public struct CleanupPlan: Sendable {
    var derivedData: Bool
    var archives: Bool
    var swiftPMCache: Bool
    /// Runner checkout dir to empty, or `nil` to leave it alone.
    var workingDirectory: String?
    var pruneSimulators: Bool
}

/// Result of a cleanup pass, for display.
public struct CleanReport: Sendable {
    public var freedBytes: Int64 = 0
    public var lines: [String] = []

    public var freedDescription: String {
        ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file)
    }
}

/// Deletes build caches. Every path here is a *cache* Xcode/SwiftPM regenerates on
/// the next build, so removing it is safe — it only costs a colder next build.
///
/// IMPORTANT: never run this while a build is in progress. Wiping DerivedData mid-build
/// corrupts the running build. The app only cleans when the runner is stopped.
enum Cleaner {

    static func clean(_ plan: CleanupPlan) async -> CleanReport {
        await Task.detached(priority: .utility) {
            var report = CleanReport()
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser

            func remove(_ url: URL, label: String) {
                let size = directorySize(url)
                guard size > 0 || fm.fileExists(atPath: url.path) else {
                    report.lines.append("• \(label): nothing to clean")
                    return
                }
                do {
                    try fm.removeItem(at: url)
                    report.freedBytes += size
                    report.lines.append(
                        "✓ \(label): freed \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                } catch {
                    report.lines.append("✗ \(label): \(error.localizedDescription)")
                }
            }

            let xcode = home
                .appendingPathComponent("Library/Developer/Xcode")

            if plan.derivedData {
                remove(xcode.appendingPathComponent("DerivedData"),
                       label: "DerivedData")
            }
            if plan.archives {
                remove(xcode.appendingPathComponent("Archives"),
                       label: "Archives")
            }
            if plan.swiftPMCache {
                remove(home.appendingPathComponent("Library/Caches/org.swift.swiftpm"),
                       label: "SwiftPM cache")
                remove(home.appendingPathComponent("Library/org.swift.swiftpm"),
                       label: "SwiftPM security cache")
            }

            // Empty the runner checkout dir *contents* but keep the dir itself,
            // so the runner can keep using it.
            if let work = plan.workingDirectory {
                let workURL = URL(fileURLWithPath: work)
                if let children = try? fm.contentsOfDirectory(
                    at: workURL, includingPropertiesForKeys: nil) {
                    for child in children {
                        remove(child, label: "workdir/\(child.lastPathComponent)")
                    }
                } else {
                    report.lines.append("• Working directory: not found (skipped)")
                }
            }

            if plan.pruneSimulators {
                let out = runShell("xcrun simctl delete unavailable")
                report.lines.append("• Simulators: pruned unavailable devices" +
                                    (out.isEmpty ? "" : " (\(out))"))
            }

            if report.lines.isEmpty {
                report.lines.append("Nothing selected to clean.")
            }
            return report
        }.value
    }

    /// Estimate reclaimable bytes without deleting, for the dashboard.
    static func estimate(_ plan: CleanupPlan) async -> Int64 {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            let xcode = home.appendingPathComponent("Library/Developer/Xcode")
            var total: Int64 = 0
            if plan.derivedData {
                total += directorySize(xcode.appendingPathComponent("DerivedData"))
            }
            if plan.archives {
                total += directorySize(xcode.appendingPathComponent("Archives"))
            }
            if plan.swiftPMCache {
                total += directorySize(home.appendingPathComponent("Library/Caches/org.swift.swiftpm"))
            }
            if let work = plan.workingDirectory {
                total += directorySize(URL(fileURLWithPath: work))
            }
            return total
        }.value
    }

    // MARK: - Helpers

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true {
                total += Int64(v?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    @discardableResult
    private static func runShell(_ command: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
