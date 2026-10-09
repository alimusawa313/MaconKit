//
//  Recap.swift
//  MaconKit
//
//  "While you were gone": what happened on this Mac since a device last
//  looked. The journal keeps the moments worth telling (an agent finished a
//  turn, one asked for permission, a prompt was answered from a phone, a
//  build passed or failed) and `GET /recap?since=` hands a device the ones
//  after its last visit, together with the prompts still up, the commits
//  made in the projects the agents touched, and anything another device did
//  to the Mac meanwhile.
//
//  The journal records all the time; "away" is the device's idea (how long
//  since it last opened the app), not the Mac's, so one Mac can serve a
//  phone that was gone an hour and an iPad that was gone a day.
//
//  Kept small and on disk, next to the audit log, so a night's work survives
//  a restart of the app.
//

import Foundation

// MARK: - Wire types

public struct CompanionRecapItemDTO: Codable, Sendable, Hashable {
    /// agent.done | agent.waiting | agent.answered | build.passed | build.failed
    public var kind: String
    public var at: Date
    public var project: String?
    /// "claude" | "codex" for agent moments.
    public var tool: String?
    /// The agent's last message (first line), the prompt, the build name.
    public var text: String?
    /// How long the agent worked on this turn.
    public var seconds: Double?
    public var agent: String?

    public init(kind: String, at: Date = Date(), project: String? = nil, tool: String? = nil,
                text: String? = nil, seconds: Double? = nil, agent: String? = nil) {
        self.kind = kind; self.at = at; self.project = project; self.tool = tool
        self.text = text; self.seconds = seconds; self.agent = agent
    }
}

/// The commits made in one project since the device last looked.
public struct CompanionRecapProjectDTO: Codable, Sendable, Hashable {
    public var name: String
    public var commits: Int
    /// The newest few subjects, newest first.
    public var subjects: [String]
    public var filesChanged: Int
    public var insertions: Int
    public var deletions: Int

    public init(name: String, commits: Int, subjects: [String], filesChanged: Int,
                insertions: Int, deletions: Int) {
        self.name = name; self.commits = commits; self.subjects = subjects
        self.filesChanged = filesChanged; self.insertions = insertions; self.deletions = deletions
    }
}

/// Another device doing something to this Mac, grouped: "iPad opened a
/// terminal 3 times".
public struct CompanionRecapAuditDTO: Codable, Sendable, Hashable {
    public var deviceName: String
    /// The audit action key ("unlocked", "terminal.opened", …); the device
    /// words it.
    public var action: String
    public var count: Int
    public var last: Date

    public init(deviceName: String, action: String, count: Int, last: Date) {
        self.deviceName = deviceName; self.action = action; self.count = count; self.last = last
    }
}

public struct CompanionRecapDTO: Codable, Sendable {
    public var since: Date
    public var now: Date
    public var macName: String
    /// Oldest first.
    public var items: [CompanionRecapItemDTO]
    /// Prompts still up right now, whenever they were asked.
    public var waiting: [CompanionCodingAgentDTO]
    public var projects: [CompanionRecapProjectDTO]
    public var audit: [CompanionRecapAuditDTO]
    /// Time any agent spent working in the window, overlaps counted once.
    public var workedSeconds: Double
    /// Prompts answered from any device in the window.
    public var answered: Int

    public init(since: Date, now: Date, macName: String, items: [CompanionRecapItemDTO],
                waiting: [CompanionCodingAgentDTO], projects: [CompanionRecapProjectDTO],
                audit: [CompanionRecapAuditDTO], workedSeconds: Double, answered: Int) {
        self.since = since; self.now = now; self.macName = macName; self.items = items
        self.waiting = waiting; self.projects = projects; self.audit = audit
        self.workedSeconds = workedSeconds; self.answered = answered
    }

    /// True when there is nothing to tell.
    public var isEmpty: Bool {
        items.isEmpty && waiting.isEmpty && projects.isEmpty && audit.isEmpty
    }
}

// MARK: - The journal

public final class RecapJournal: @unchecked Sendable {

    /// A stretch of time an agent spent working, for the "worked" number.
    struct Span: Codable, Hashable {
        var start: Date
        var end: Date
    }

    private struct Stored: Codable {
        var items: [CompanionRecapItemDTO]
        var spans: [Span]
        /// Project folders by name, so commits can be counted later.
        var folders: [String: String]
    }

    private let lock = NSLock()
    private let url: URL?
    private var items: [CompanionRecapItemDTO] = []
    private var spans: [Span] = []
    private var folders: [String: String] = [:]
    /// What each session was doing at the last observation, and since when
    /// it has been running.
    private var lastState: [String: String] = [:]
    private var runningSince: [String: Date] = [:]
    private var lastDecisions: [String: Int] = [:]
    private var lastSeq: [String: Int] = [:]

    /// A week of moments at most, and never more than this many.
    private let keepFor: TimeInterval = 7 * 24 * 60 * 60
    private let keepCount = 600

    /// `url` nil keeps the journal in memory (tests, the CLI).
    public init(url: URL? = nil) {
        self.url = url
        guard let url, let data = try? Data(contentsOf: url),
              let stored = try? Self.decoder.decode(Stored.self, from: data) else { return }
        items = stored.items
        spans = stored.spans
        folders = stored.folders
    }

    /// The app's journal, in the companion folder beside the audit log.
    public static func defaultURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MacON/companion/recap.json")
    }

    // MARK: Recording

    /// Look at the sessions after any change in the hub and note what moved:
    /// a turn finished, a prompt came up, a prompt was answered. Diffing the
    /// whole list rather than reacting to single events means nothing is
    /// missed when events arrive faster than the app hears about them.
    public func observe(_ agents: [CompanionCodingAgentDTO], now: Date = Date()) {
        lock.lock()
        var changed = false
        for agent in agents {
            let before = lastState[agent.id]
            if !agent.cwd.isEmpty { folders[agent.project] = agent.cwd }

            if agent.state == "running" || agent.state == "waiting" {
                if runningSince[agent.id] == nil { runningSince[agent.id] = agent.since }
            }
            if agent.state == "waiting", let prompt = agent.prompt, lastSeq[agent.id] != prompt.seq {
                lastSeq[agent.id] = prompt.seq
                items.append(CompanionRecapItemDTO(
                    kind: "agent.waiting", at: prompt.askedAt, project: agent.project, tool: agent.tool,
                    text: SecretFilter.clean("\(prompt.tool): \(prompt.summary)", limit: 160),
                    agent: agent.id))
                changed = true
            }
            if agent.decisions > (lastDecisions[agent.id] ?? agent.decisions) {
                for _ in 0..<(agent.decisions - (lastDecisions[agent.id] ?? 0)) {
                    items.append(CompanionRecapItemDTO(kind: "agent.answered", at: now,
                                                       project: agent.project, tool: agent.tool,
                                                       agent: agent.id))
                }
                changed = true
            }
            lastDecisions[agent.id] = agent.decisions

            let finishedNow = (agent.state == "idle" || agent.state == "ended")
                && before != nil && before != "idle" && before != "ended"
            if finishedNow {
                let start = runningSince.removeValue(forKey: agent.id)
                if let start, agent.since > start { spans.append(Span(start: start, end: agent.since)) }
                items.append(CompanionRecapItemDTO(
                    kind: "agent.done", at: agent.since, project: agent.project, tool: agent.tool,
                    text: agent.lastMessage.flatMap { SecretFilter.clean(Self.firstLine($0), limit: 200) },
                    seconds: start.map { max(0, agent.since.timeIntervalSince($0)) },
                    agent: agent.id))
                changed = true
            }
            lastState[agent.id] = agent.state
        }
        // Sessions the hub forgot: close their spans quietly.
        let present = Set(agents.map(\.id))
        for id in Array(lastState.keys) where !present.contains(id) {
            if let start = runningSince.removeValue(forKey: id) { spans.append(Span(start: start, end: now)) }
            lastState[id] = nil; lastDecisions[id] = nil; lastSeq[id] = nil
            changed = true
        }
        if changed { trimAndSave(now: now) }
        lock.unlock()
    }

    /// A build finished.
    public func noteBuild(passed: Bool, name: String, detail: String?, at: Date = Date()) {
        lock.lock()
        items.append(CompanionRecapItemDTO(kind: passed ? "build.passed" : "build.failed", at: at,
                                           project: name,
                                           text: detail.map { SecretFilter.clean($0, limit: 160) }))
        trimAndSave(now: at)
        lock.unlock()
    }

    // MARK: Reading

    /// Everything a device needs to say what happened since `since`.
    /// `live` is the hub's list right now (for the prompts still up and the
    /// spans still open); `audit` is the log's recent lines; `requester` is
    /// the calling device's token prefix, whose own doings are left out.
    public func recap(since: Date, now: Date = Date(), macName: String,
                      live: [CompanionCodingAgentDTO], audit: [AuditEntry], requester: String,
                      commits: (String, Date) -> CompanionRecapProjectDTO? = RecapJournal.gitCommits) -> CompanionRecapDTO {
        lock.lock()
        let window = items.filter { $0.at > since && $0.at <= now }.sorted { $0.at < $1.at }
        var worked = spans
        for (_, start) in runningSince { worked.append(Span(start: start, end: now)) }
        let folderMap = folders
        lock.unlock()

        let waiting = live.filter { $0.state == "waiting" && $0.prompt != nil }
        let touched = Set(window.compactMap { $0.kind.hasPrefix("agent.") ? $0.project : nil })
            .union(live.filter { $0.since > since }.map(\.project))
        let projects = touched.sorted().compactMap { name -> CompanionRecapProjectDTO? in
            guard let folder = folderMap[name] else { return nil }
            guard var found = commits(folder, since), found.commits > 0 else { return nil }
            found.name = name
            return found
        }

        return CompanionRecapDTO(
            since: since, now: now, macName: macName, items: window, waiting: waiting,
            projects: projects, audit: Self.group(audit, since: since, now: now, requester: requester),
            workedSeconds: Self.covered(worked, from: since, to: now),
            answered: window.filter { $0.kind == "agent.answered" }.count)
    }

    // MARK: Pieces

    /// The audit actions worth a line in a recap: the ones where another
    /// device reached into this Mac. Reads and small housekeeping are not.
    public static let notableAudit: Set<String> = [
        "paired", "unpaired", "unlocked", "woke", "locked", "curtain",
        "screen.viewed", "control.started", "mic.started", "terminal.opened",
        "file.written", "file.deleted", "file.moved", "code.written",
        "flow.run", "build.install", "agent.task", "compact.opened",
    ]

    static func group(_ audit: [AuditEntry], since: Date, now: Date, requester: String) -> [CompanionRecapAuditDTO] {
        var groups: [String: CompanionRecapAuditDTO] = [:]
        for entry in audit where entry.at > since && entry.at <= now
            && entry.device != requester && notableAudit.contains(entry.action) {
            let name = entry.deviceName ?? entry.device
            let key = "\(name)|\(entry.action)"
            if var g = groups[key] {
                g.count += 1
                g.last = max(g.last, entry.at)
                groups[key] = g
            } else {
                groups[key] = CompanionRecapAuditDTO(deviceName: name, action: entry.action, count: 1, last: entry.at)
            }
        }
        return groups.values.sorted { $0.last > $1.last }
    }

    /// Seconds of [from, to] covered by at least one span.
    static func covered(_ spans: [Span], from: Date, to: Date) -> Double {
        let clipped = spans.compactMap { s -> Span? in
            let a = max(s.start, from), b = min(s.end, to)
            return b > a ? Span(start: a, end: b) : nil
        }.sorted { $0.start < $1.start }
        var total: Double = 0
        var current: Span?
        for s in clipped {
            if var c = current, s.start <= c.end {
                c.end = max(c.end, s.end); current = c
            } else {
                if let c = current { total += c.end.timeIntervalSince(c.start) }
                current = s
            }
        }
        if let c = current { total += c.end.timeIntervalSince(c.start) }
        return total
    }

    /// Commits in `folder` since `since`, by anyone: the agent commits as the
    /// user. `git` straight, never through a shell, so a folder name can't
    /// become a command. Nil when the folder is not a repository.
    public static func gitCommits(folder: String, since: Date) -> CompanionRecapProjectDTO? {
        let stamp = "@\(Int(since.timeIntervalSince1970))"
        guard let log = git(["log", "--since=\(stamp)", "--no-merges", "--pretty=format:%s", "-n", "200"],
                            in: folder) else { return nil }
        let subjects = log.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !subjects.isEmpty else {
            return CompanionRecapProjectDTO(name: "", commits: 0, subjects: [], filesChanged: 0,
                                            insertions: 0, deletions: 0)
        }
        var files = 0, plus = 0, minus = 0
        if let stat = git(["log", "--since=\(stamp)", "--no-merges", "--shortstat", "--pretty=format:"], in: folder) {
            for line in stat.split(separator: "\n") {
                // " 3 files changed, 40 insertions(+), 2 deletions(-)"
                for part in line.split(separator: ",") {
                    let words = part.split(separator: " ")
                    guard let n = words.first.flatMap({ Int($0) }), words.count > 1 else { continue }
                    if words[1].hasPrefix("file") { files += n }
                    else if words[1].hasPrefix("insertion") { plus += n }
                    else if words[1].hasPrefix("deletion") { minus += n }
                }
            }
        }
        return CompanionRecapProjectDTO(
            name: "", commits: subjects.count,
            subjects: subjects.prefix(3).map { SecretFilter.clean($0, limit: 120) },
            filesChanged: files, insertions: plus, deletions: minus)
    }

    private static func git(_ args: [String], in folder: String) -> String? {
        // Only inside a repository: an agent often runs in a subfolder, so
        // look upwards for the .git. Checking first also keeps git (and, on
        // a Mac without the developer tools, its install prompt) away from
        // folders that were never repositories.
        guard let root = repositoryRoot(folder) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", root] + args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func repositoryRoot(_ folder: String) -> String? {
        var url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            let up = url.deletingLastPathComponent()
            if up.path == url.path { return nil }
            url = up
        }
        return nil
    }

    /// Called with the lock held.
    private func trimAndSave(now: Date) {
        let cutoff = now.addingTimeInterval(-keepFor)
        items.removeAll { $0.at < cutoff }
        if items.count > keepCount { items.removeFirst(items.count - keepCount) }
        spans.removeAll { $0.end < cutoff }
        guard let url else { return }
        let stored = Stored(items: items, spans: spans, folders: folders)
        guard let data = try? Self.encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? text
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}

// MARK: - Secrets

/// Agents quote whatever they last touched, and that is sometimes a key.
/// Anything that leaves the Mac as a summary line (a Lock Screen card, a
/// recap) goes through here first. Deliberately blunt: a false positive
/// costs a few masked characters, a miss costs a leaked token.
public enum SecretFilter {
    private static let patterns: [NSRegularExpression] = [
        // Provider keys with a recognisable prefix.
        #"\b(sk|pk|rk)-[A-Za-z0-9_\-]{16,}"#,
        #"\bsk-ant-[A-Za-z0-9_\-]{16,}"#,
        #"\bgh[pousr]_[A-Za-z0-9]{20,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bAIza[0-9A-Za-z_\-]{30,}"#,
        #"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#,
        // key=value and "Bearer x" shapes.
        #"(?i)\b(password|passwd|secret|token|api[_-]?key|authorization)\b\s*[:=]\s*\S+"#,
        #"(?i)\bbearer\s+[A-Za-z0-9._\-]{12,}"#,
        // Long unbroken hex or base64 runs.
        #"\b[A-Fa-f0-9]{40,}\b"#,
        #"\b[A-Za-z0-9+/]{48,}={0,2}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func clean(_ text: String, limit: Int = 200) -> String {
        var out = text.replacingOccurrences(of: "\n", with: " ")
        for regex in patterns {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "•••")
        }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.count > limit ? String(out.prefix(limit - 1)) + "…" : out
    }
}
