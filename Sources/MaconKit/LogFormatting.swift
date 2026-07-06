//
//  LogFormatting.swift
//  MaconKit
//
//  Pure log-processing logic shared by the app (Steps view) and the CLI.
//

import Foundation

extension String {
    /// Remove ANSI colour escape codes (fastlane/xcpretty emit lots of these).
    public func strippingANSI() -> String {
        guard let re = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m") else { return self }
        let range = NSRange(startIndex..., in: self)
        return re.stringByReplacingMatches(in: self, range: range, withTemplate: "")
    }
}

/// Human-friendly duration.
public func formatDuration(_ t: TimeInterval) -> String {
    let t = max(0, t)
    if t < 1 { return String(format: "%.0fms", t * 1000) }
    if t < 60 { return String(format: "%.1fs", t) }
    let s = Int(t.rounded())
    return "\(s / 60)m \(s % 60)s"
}

/// Total wall time spanned by a set of log lines.
public func totalDuration(_ lines: [LogLine]) -> TimeInterval {
    guard let first = lines.first?.date, let last = lines.last?.date else { return 0 }
    return last.timeIntervalSince(first)
}

/// One collapsible section of a parsed log (a command, a fastlane step, a phase…).
public struct LogSection: Identifiable {
    public enum Kind { case command, step, phase, output }
    public let id: Int
    public var title: String
    public var lines: [LogLine]
    public var kind: Kind
    public var startDate: Date
    public var endDate: Date

    public var duration: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }

    // Precise failure detection — avoids false positives like the fastlane
    // setting line "slack_only_on_failure | false".
    public var failed: Bool {
        lines.contains { l0 in
            let l = l0.text
            if l.contains("❌") { return true }
            if l.contains("** BUILD FAILED") || l.contains("** TEST FAILED")
                || l.contains("TEST EXECUTE FAILED") || l.contains("fatal error:") { return true }
            return l.range(of: #"with [1-9][0-9]* failure"#, options: .regularExpression) != nil
        }
    }
    public var succeeded: Bool {
        lines.contains {
            let l = $0.text
            return l.contains("✅") || l.contains("** BUILD SUCCEEDED")
                || l.contains("Build Succeeded") || l.contains("with 0 failures")
                || l.contains("Tests Passed")
        }
    }
}

/// Parse a flat log into collapsible sections keyed off command / fastlane-step markers.
public func parseLogSections(_ lines: [LogLine]) -> [LogSection] {
    var sections: [LogSection] = []
    var current: LogSection?

    func flush() { if let c = current { sections.append(c) }; current = nil }
    func start(_ title: String, _ kind: LogSection.Kind, _ date: Date) {
        flush()
        current = LogSection(id: sections.count, title: title, lines: [],
                             kind: kind, startDate: date, endDate: date)
    }

    for line in lines {
        let t = line.text.strippingANSI()
        if t.hasPrefix("──────") {
            let name = t.replacingOccurrences(of: "─", with: "").trimmingCharacters(in: .whitespaces)
            start(name.isEmpty ? "Build" : name.capitalized, .phase, line.date)
        } else if t.hasPrefix("$ ") {
            start(String(t.dropFirst(2)), .command, line.date)
        } else if let r = t.range(of: "--- Step: ") {
            let name = t[r.upperBound...].replacingOccurrences(of: "---", with: "")
                .trimmingCharacters(in: .whitespaces)
            start(name, .step, line.date)
        } else {
            if current == nil { start("Output", .output, line.date) }
            current?.lines.append(line)
        }
    }
    flush()

    // A step's duration runs until the next step starts (last step → final line).
    let lastDate = lines.last?.date
    for i in sections.indices {
        sections[i].endDate = (i + 1 < sections.count) ? sections[i + 1].startDate
                                                        : (lastDate ?? sections[i].startDate)
    }
    return sections
}
