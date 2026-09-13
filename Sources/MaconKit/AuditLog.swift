//
//  AuditLog.swift
//  MaconKit
//
//  Who did what to this Mac from a paired device, and when. Every remote
//  power is off by default and behind a toggle; this is the other half of
//  that promise: once something is on, its use leaves a line. Pairings,
//  unlocks, wakes, the curtain, control and screen sessions, terminals,
//  file writes and deletes, flows and agent tasks, a phone answering a
//  coding agent's prompt, an app installed on a device.
//
//  One JSON object per line, appended, in the companion folder next to the
//  pairings. Kept to a few thousand lines: old ones fall off the top. Read
//  by the app's Settings pane and by `macon companion activity`.
//

import Foundation

public struct AuditEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var at: Date
    /// The device's token prefix (stable for a pairing) and its name at the
    /// time, so a line still reads after the device is unpaired.
    public var device: String
    public var deviceName: String?
    /// A short verb-ish key: "paired", "unlocked", "control.started", …
    public var action: String
    public var detail: String?
    /// "lan" | "tunnel" | "icloud" | "cli"
    public var via: String?

    public init(id: UUID = UUID(), at: Date = Date(), device: String, deviceName: String? = nil,
                action: String, detail: String? = nil, via: String? = nil) {
        self.id = id; self.at = at; self.device = device; self.deviceName = deviceName
        self.action = action; self.detail = detail; self.via = via
    }
}

public final class AuditLog: @unchecked Sendable {
    public static let shared = AuditLog()

    /// Fires after each line is written, on the caller's thread.
    public var onAppend: (@Sendable (AuditEntry) -> Void)?

    private let lock = NSLock()
    private let url: URL
    /// Lines kept after a compaction, and the count that triggers one.
    private let keep = 2000
    private let compactAt = 2600
    private var appendedSinceCheck = 0

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            self.url = base.appendingPathComponent("MacON/companion/audit.jsonl")
        }
    }

    public var fileURL: URL { url }

    // MARK: Writing

    @discardableResult
    public func record(device: String, deviceName: String? = nil, action: String,
                       detail: String? = nil, via: String? = nil) -> AuditEntry {
        let entry = AuditEntry(device: device, deviceName: deviceName, action: action,
                               detail: detail.map { String($0.prefix(300)) }, via: via)
        lock.lock()
        write(entry)
        appendedSinceCheck += 1
        if appendedSinceCheck >= 50 { appendedSinceCheck = 0; compactIfNeeded() }
        lock.unlock()
        onAppend?(entry)
        return entry
    }

    private func write(_ entry: AuditEntry) {
        guard var data = try? Self.encoder.encode(entry) else { return }
        data.append(0x0A)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Drop the oldest lines once the file has grown past the ceiling.
    private func compactIfNeeded() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > compactAt else { return }
        let kept = lines.suffix(keep).joined(separator: "\n") + "\n"
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Reading

    /// The newest `limit` entries, newest first.
    public func recent(limit: Int = 200) -> [AuditEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(limit).reversed().compactMap {
            try? Self.decoder.decode(AuditEntry.self, from: Data($0.utf8))
        }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    /// The whole log as text, for export: one readable line per entry.
    public func exportText() -> String {
        let f = ISO8601DateFormatter()
        return recent(limit: Int.max).reversed().map { e in
            var line = "\(f.string(from: e.at))  \(e.deviceName ?? e.device)  \(e.action)"
            if let d = e.detail, !d.isEmpty { line += "  \(d)" }
            if let v = e.via { line += "  (\(v))" }
            return line
        }.joined(separator: "\n") + "\n"
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    // MARK: What counts

    /// Which requests leave a line, and under what name. Reads never do (a
    /// build list, a screenshot poll) and neither does anything a device
    /// does to itself (its own push token). What is left is the set of
    /// things a person would want to know happened while they were away.
    public static func action(method: String, path: String, segs: [String],
                              isUpgrade: Bool, body: Data) -> (action: String, detail: String?)? {
        func json() -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
        func str(_ key: String) -> String? {
            let v = json()[key]
            if let s = v as? String { return s }
            if let b = v as? Bool { return b ? "on" : "off" }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
        switch (method, segs.first ?? "") {
        case ("POST", "unpair"):   return ("unpaired", nil)
        case ("GET", "screen") where isUpgrade:   return ("screen.viewed", nil)
        case ("GET", "control") where isUpgrade:  return ("control.started", nil)
        case ("POST", "control") where segs.count == 2 && segs[1] == "once":
            return ("control.event", str("t"))
        case ("GET", "mic") where isUpgrade:      return ("mic.started", nil)
        case ("GET", "term") where isUpgrade:     return ("terminal.opened", nil)
        case ("POST", "compact"):  return ("compact.opened", str("appPath") ?? str("app_path"))
        case ("POST", "open"):     return ("link.opened", str("url"))
        case ("POST", "clipboard"): return ("clipboard.pushed", nil)
        case ("POST", "power") where segs.count == 2:
            switch segs[1] {
            case "wake":    return ("woke", nil)
            case "unlock":  return ("unlocked", nil)
            case "lock":    return ("locked", nil)
            case "privacy": return ("curtain", str("on") ?? "on")
            default:        return nil
            }
        case ("POST", "audio") where segs.count == 2 && segs[1] == "output":
            return ("audio.output", str("uid"))
        case ("POST", "agent") where segs.count == 2 && segs[1] == "task":
            return ("agent.task", str("task"))
        case ("POST", "agent") where segs.count == 3 && segs[2] == "decision":
            return ("agent.decision", str("approve"))
        case ("POST", "agent") where segs.count == 3 && segs[2] == "stop":
            return ("agent.stopped", nil)
        case ("POST", "coding-agents") where segs.count == 3 && segs[2] == "decision":
            return ("coding.decision", str("allow").map { $0 == "on" ? "allow" : "deny" })
        case ("PUT", "files"):     return ("file.written", pathQuery(path))
        case ("POST", "files") where segs.count == 2:
            switch segs[1] {
            case "delete": return ("file.deleted", str("path"))
            case "move":   return ("file.moved", [str("from"), str("to")].compactMap { $0 }.joined(separator: " → "))
            case "mkdir":  return ("folder.created", str("path"))
            default:       return nil
            }
        case ("PUT", "code"):      return ("code.written", pathQuery(path))
        case ("POST", "code") where segs.count == 2 && segs[1] == "open":
            return ("code.opened", str("path"))
        case ("POST", "flows") where segs.count == 3 && segs[2] == "run":
            return ("flow.run", segs[1])
        case ("PUT", "flows"):     return ("flows.saved", nil)
        case ("DELETE", "flows"):  return ("flow.deleted", segs.count > 1 ? segs[1] : nil)
        case ("POST", "pipelines") where segs.count == 1:
            return ("pipeline.created", str("name"))
        case ("PUT", "pipelines"): return ("pipeline.edited", segs.count > 1 ? segs[1] : nil)
        case ("DELETE", "pipelines"): return ("pipeline.deleted", segs.count > 1 ? segs[1] : nil)
        case ("POST", "pipelines") where segs.count == 3:
            return ("pipeline.\(segs[2])", segs[1])
        case ("POST", "builds") where segs.count == 3:
            return ("build.\(segs[2])", segs[2] == "install" ? str("device") : segs[1])
        default:
            return nil
        }
    }

    private static func pathQuery(_ path: String) -> String? {
        guard let q = path.split(separator: "?").dropFirst().first else { return nil }
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "path" { return String(kv[1]).removingPercentEncoding }
        }
        return nil
    }
}
