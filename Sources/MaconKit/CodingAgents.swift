//
//  CodingAgents.swift
//  MaconKit
//
//  The coding agents running on this Mac (Claude Code, Codex), seen from a
//  paired device. An agent reports its moments through a hook: it started,
//  it is working, it wants permission to run something, it finished, the
//  session ended. `macon hook claude` is that hook, installed into Claude
//  Code's settings; `macon hook codex` is the Codex `notify` command. Both
//  post here through the companion server, so the phone gets a push when an
//  agent is waiting and can answer the prompt from wherever it is.
//
//  Whether a permission prompt is HELD for the phone is a policy decision the
//  app makes, not the hook: when somebody is at the Mac the dialog belongs on
//  the Mac, so the hook returns straight away and Claude shows it there. When
//  the Mac is idle or locked, the hook waits for the phone's answer (or for
//  the person to come back to the Mac, which releases it).
//

import Foundation

// MARK: - Wire types

/// One prompt an agent is waiting on: "Claude wants to run `git push`".
public struct CompanionCodingAgentPromptDTO: Codable, Sendable, Hashable {
    public var seq: Int
    /// The agent's tool name ("Bash", "Edit", "WebFetch", …).
    public var tool: String
    /// One line: the command, the file, the URL.
    public var summary: String
    /// More of the input, when the summary is not the whole story.
    public var detail: String?
    public var askedAt: Date

    public init(seq: Int, tool: String, summary: String, detail: String? = nil, askedAt: Date = Date()) {
        self.seq = seq; self.tool = tool; self.summary = summary; self.detail = detail; self.askedAt = askedAt
    }
}

/// One agent session as the device sees it.
public struct CompanionCodingAgentDTO: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    /// "claude" | "codex" | anything else a hook names.
    public var tool: String
    /// The project folder's name, for the row.
    public var project: String
    public var cwd: String
    /// running | waiting | idle | ended
    public var state: String
    /// When the current state began.
    public var since: Date
    public var startedAt: Date
    /// What the agent last said when it stopped, when the hook could read it.
    public var lastMessage: String?
    /// The prompt it is waiting on, while `state == "waiting"`.
    public var prompt: CompanionCodingAgentPromptDTO?
    /// Prompts answered from a device in this session.
    public var decisions: Int

    public init(id: String, tool: String, project: String, cwd: String, state: String,
                since: Date, startedAt: Date, lastMessage: String? = nil,
                prompt: CompanionCodingAgentPromptDTO? = nil, decisions: Int = 0) {
        self.id = id; self.tool = tool; self.project = project; self.cwd = cwd
        self.state = state; self.since = since; self.startedAt = startedAt
        self.lastMessage = lastMessage; self.prompt = prompt; self.decisions = decisions
    }
}

public struct CompanionCodingAgentsDTO: Codable, Sendable {
    public var agents: [CompanionCodingAgentDTO]
    public init(agents: [CompanionCodingAgentDTO]) { self.agents = agents }
}

/// The device's answer to a prompt.
public struct CompanionCodingAgentDecisionDTO: Codable, Sendable {
    public var seq: Int
    public var allow: Bool
    /// Shown to the agent on a deny, so it knows why.
    public var message: String?
    public init(seq: Int, allow: Bool, message: String? = nil) {
        self.seq = seq; self.allow = allow; self.message = message
    }
}

/// What a hook posts (POST /coding-agents/hook).
public struct CodingAgentHookEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A session began.
        case start
        /// The user sent a prompt / the agent is working again.
        case working
        /// The agent wants permission for a tool call.
        case permission
        /// A notification the agent raised (idle, needs input) — informational.
        case notification
        /// The agent finished its turn.
        case stop
        /// The session ended.
        case end
    }

    public var session: String
    public var tool: String
    public var cwd: String
    public var kind: Kind
    public var message: String?
    public var prompt: Prompt?

    public struct Prompt: Codable, Sendable {
        public var tool: String
        public var summary: String
        public var detail: String?
        public init(tool: String, summary: String, detail: String? = nil) {
            self.tool = tool; self.summary = summary; self.detail = detail
        }
    }

    public init(session: String, tool: String, cwd: String, kind: Kind,
                message: String? = nil, prompt: Prompt? = nil) {
        self.session = session; self.tool = tool; self.cwd = cwd; self.kind = kind
        self.message = message; self.prompt = prompt
    }
}

/// What the hook gets back. For a permission: the prompt's `seq`, whether
/// the Mac wants the hook to hold for a device's answer, and the answer
/// itself if one arrived inside the request's wait.
public struct CodingAgentHookResponse: Codable, Sendable {
    public var seq: Int?
    public var hold: Bool
    public var decision: CompanionCodingAgentDecisionDTO?
    public init(seq: Int? = nil, hold: Bool = false, decision: CompanionCodingAgentDecisionDTO? = nil) {
        self.seq = seq; self.hold = hold; self.decision = decision
    }
}

// MARK: - Hub

/// The sessions, their prompts, and the rendezvous between a hook waiting
/// for an answer and a device giving one. Thread-safe; the server calls it
/// from its queue and the app from the main actor.
public final class CodingAgentHub: @unchecked Sendable {

    public enum Change: Sendable {
        /// An agent is waiting on a prompt — worth a push.
        case waiting(CompanionCodingAgentDTO)
        /// An agent finished its turn — worth a push.
        case finished(CompanionCodingAgentDTO)
        /// Anything else moved (list refresh only).
        case updated
    }

    /// Fired off the lock, on whatever thread posted the event.
    public var onChange: (@Sendable (Change) -> Void)?

    /// Whether a permission prompt should be held for a device right now.
    /// The app answers from presence (somebody at the keyboard, screen
    /// unlocked → false). Nil means always hold, which is right for a Mac
    /// nobody sits at.
    public var shouldHold: (@Sendable () -> Bool)?

    private let lock = NSLock()
    private var agents: [String: CompanionCodingAgentDTO] = [:]
    private var seq = 0
    /// Answers by "session#seq", kept until the hook collects them.
    private var answers: [String: CompanionCodingAgentDecisionDTO] = [:]
    private var waiters: [String: [CheckedContinuation<CompanionCodingAgentDecisionDTO?, Never>]] = [:]

    /// Sessions that ended are kept this long so the list can show "done".
    private let endedRetention: TimeInterval = 60 * 60
    /// Sessions that went quiet without an end are dropped after this.
    private let staleRetention: TimeInterval = 12 * 60 * 60

    public init() {}

    // MARK: Hook side

    /// Record a hook event. For a permission the response names the prompt
    /// and says whether to hold; the hook then long-polls `waitDecision`.
    public func apply(_ event: CodingAgentHookEvent) -> CodingAgentHookResponse {
        let now = Date()
        var change: Change = .updated
        var response = CodingAgentHookResponse()

        lock.lock()
        prune(now: now)
        var agent = agents[event.session] ?? CompanionCodingAgentDTO(
            id: event.session, tool: event.tool,
            project: Self.projectName(event.cwd), cwd: event.cwd,
            state: "running", since: now, startedAt: now)
        agent.tool = event.tool
        if !event.cwd.isEmpty { agent.cwd = event.cwd; agent.project = Self.projectName(event.cwd) }

        switch event.kind {
        case .start:
            agent.state = "running"; agent.since = now; agent.prompt = nil
        case .working:
            // A prompt that is still up was answered at the Mac: drop it.
            if agent.prompt != nil { dropWaiters(for: agent) }
            agent.state = "running"; agent.since = now; agent.prompt = nil
        case .permission:
            seq += 1
            let prompt = CompanionCodingAgentPromptDTO(
                seq: seq, tool: event.prompt?.tool ?? "Tool",
                summary: event.prompt?.summary ?? (event.message ?? ""),
                detail: event.prompt?.detail, askedAt: now)
            agent.state = "waiting"; agent.since = now; agent.prompt = prompt
            response.seq = seq
            response.hold = shouldHold?() ?? true
            change = .waiting(agent)
        case .notification:
            // "Claude needs your permission" arrives here too, from the
            // Notification hook, when the PermissionRequest hook did not
            // (older Claude). Only note it if nothing is already up.
            if agent.prompt == nil, let message = event.message {
                let lower = message.lowercased()
                if lower.contains("permission") || lower.contains("approve") {
                    seq += 1
                    agent.prompt = CompanionCodingAgentPromptDTO(seq: seq, tool: "Prompt", summary: message, askedAt: now)
                    agent.state = "waiting"; agent.since = now
                    response.seq = seq
                    change = .waiting(agent)
                } else if lower.contains("waiting") || lower.contains("input") {
                    agent.state = "idle"; agent.since = now
                    agent.lastMessage = message
                    change = .finished(agent)
                }
            }
        case .stop:
            if agent.prompt != nil { dropWaiters(for: agent) }
            agent.state = "idle"; agent.since = now; agent.prompt = nil
            if let message = event.message, !message.isEmpty { agent.lastMessage = message }
            change = .finished(agent)
        case .end:
            if agent.prompt != nil { dropWaiters(for: agent) }
            agent.state = "ended"; agent.since = now; agent.prompt = nil
        }
        agents[event.session] = agent
        lock.unlock()

        onChange?(change)
        return response
    }

    /// Hold up to `timeout` for a device's answer to (session, seq). Returns
    /// nil when none came — the hook polls again, or gives the dialog back to
    /// the Mac when its own deadline passes or presence says so.
    public func waitDecision(session: String, seq: Int, timeout: TimeInterval) async -> CompanionCodingAgentDecisionDTO? {
        let key = "\(session)#\(seq)"
        switch readyAnswer(session: session, seq: seq, key: key) {
        case .answered(let ready): return ready
        case .gone: return nil
        case .pending: break
        }

        let clamped = max(1, min(timeout, 25))
        return await withTaskGroup(of: CompanionCodingAgentDecisionDTO?.self) { group in
            group.addTask { [self] in
                await withCheckedContinuation { (c: CheckedContinuation<CompanionCodingAgentDecisionDTO?, Never>) in
                    self.lock.lock()
                    if let ready = self.answers.removeValue(forKey: key) {
                        self.lock.unlock(); c.resume(returning: ready); return
                    }
                    self.waiters[key, default: []].append(c)
                    self.lock.unlock()
                }
            }
            group.addTask { [self] in
                try? await Task.sleep(for: .seconds(clamped))
                self.timeOut(key)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private enum Ready { case answered(CompanionCodingAgentDecisionDTO), gone, pending }

    /// The synchronous half of `waitDecision`: an answer already here, a
    /// prompt that is gone (answered at the Mac, session moved on), or one
    /// still worth waiting on. Keeps the lock out of the async function.
    private func readyAnswer(session: String, seq: Int, key: String) -> Ready {
        lock.lock(); defer { lock.unlock() }
        if let ready = answers.removeValue(forKey: key) { return .answered(ready) }
        guard agents[session]?.prompt?.seq == seq else { return .gone }
        return .pending
    }

    /// The timer fired: release every waiter on this key with "nothing yet".
    private func timeOut(_ key: String) {
        lock.lock()
        let pending = waiters.removeValue(forKey: key) ?? []
        lock.unlock()
        for c in pending { c.resume(returning: nil) }
    }

    /// Prompt gone without an answer (answered at the Mac, or the session
    /// moved on): release its waiters. Called with the lock held.
    private func dropWaiters(for agent: CompanionCodingAgentDTO) {
        guard let seq = agent.prompt?.seq else { return }
        let key = "\(agent.id)#\(seq)"
        let pending = waiters.removeValue(forKey: key) ?? []
        answers[key] = nil
        // Resume outside the lock's critical path would be cleaner, but these
        // continuations only hop back to a Task; nothing re-enters the hub.
        for c in pending { c.resume(returning: nil) }
    }

    // MARK: Device side

    public func list() -> [CompanionCodingAgentDTO] {
        lock.lock(); defer { lock.unlock() }
        prune(now: Date())
        return agents.values.sorted { a, b in
            // Waiting first, then by recency.
            if (a.state == "waiting") != (b.state == "waiting") { return a.state == "waiting" }
            return a.since > b.since
        }
    }

    public func agent(_ id: String) -> CompanionCodingAgentDTO? {
        lock.lock(); defer { lock.unlock() }
        return agents[id]
    }

    /// A device answered. False when the prompt is not the one still up.
    @discardableResult
    public func decide(session: String, _ decision: CompanionCodingAgentDecisionDTO) -> Bool {
        lock.lock()
        guard var agent = agents[session], agent.prompt?.seq == decision.seq else {
            lock.unlock(); return false
        }
        let key = "\(session)#\(decision.seq)"
        agent.prompt = nil
        agent.state = "running"; agent.since = Date()
        agent.decisions += 1
        agents[session] = agent
        let pending = waiters.removeValue(forKey: key) ?? []
        if pending.isEmpty { answers[key] = decision }
        lock.unlock()
        for c in pending { c.resume(returning: decision) }
        onChange?(.updated)
        return true
    }

    /// Forget a session (a device swiped it away).
    @discardableResult
    public func remove(_ id: String) -> Bool {
        lock.lock()
        guard let agent = agents.removeValue(forKey: id) else { lock.unlock(); return false }
        dropWaiters(for: agent)
        lock.unlock()
        onChange?(.updated)
        return true
    }

    /// How many prompts are up right now.
    public var waitingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return agents.values.filter { $0.state == "waiting" }.count
    }

    // MARK: Housekeeping

    /// Called with the lock held.
    private func prune(now: Date) {
        for (id, agent) in agents {
            let age = now.timeIntervalSince(agent.since)
            if agent.state == "ended", age > endedRetention { agents[id] = nil }
            else if age > staleRetention { agents[id] = nil }
        }
    }

    static func projectName(_ cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

// MARK: - Installing the hooks

/// Wires `macon hook …` into the agents' own config files, and takes it out
/// again. Claude Code reads `~/.claude/settings.json`; Codex reads
/// `~/.codex/config.toml`. Both edits are idempotent and leave everything
/// else in the file alone.
public enum CodingAgentHooks {

    public enum Agent: String, CaseIterable, Sendable {
        case claude, codex
    }

    /// The `macon` executable the hooks run. The app carries one inside its
    /// bundle, so nobody has to install anything; that copy wins whenever the
    /// caller is the app. A CLI on PATH is next (Homebrew), then whatever is
    /// running now. Nil = nothing to point a hook at.
    public static func executable() -> String? {
        let fm = FileManager.default
        // Contents/Helpers, not Contents/MacOS: the app's own executable is
        // "MacON", and on a case-insensitive disk that is the same name.
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/macon").path
        if fm.isExecutableFile(atPath: bundled) { return bundled }
        let own = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        if own.hasSuffix("/macon"), fm.isExecutableFile(atPath: own) { return own }
        for candidate in ["/opt/homebrew/bin/macon", "/usr/local/bin/macon"]
        where fm.isExecutableFile(atPath: candidate) { return candidate }
        return nil
    }

    /// Whether Codex is set up on this Mac at all; a fresh config.toml for a
    /// tool the person never installed would only puzzle them.
    public static var codexPresent: Bool {
        FileManager.default.fileExists(atPath: codexConfigURL.deletingLastPathComponent().path)
    }

    /// Point installed hooks at `exe` if they name anything else: the app
    /// moved (DerivedData to /Applications), or an older install used the
    /// Homebrew path. Returns which agents were rewritten.
    @discardableResult
    public static func repair(exe: String, port: Int?) -> [Agent] {
        var fixed: [Agent] = []
        if claudeInstalled(), !claudeCommands().allSatisfy({ $0.hasPrefix(exe + " ") || $0 == exe }) {
            if (try? installClaude(exe: exe, port: port)) != nil { fixed.append(.claude) }
        }
        if codexInstalled(), let text = try? String(contentsOf: codexConfigURL, encoding: .utf8),
           !text.contains("\"\(exe)\"") {
            if (try? installCodex(exe: exe, port: port)) != nil { fixed.append(.codex) }
        }
        return fixed
    }

    /// The commands our Claude entries run, for the repair check.
    public static func claudeCommands() -> [String] {
        guard let root = readJSON(claudeSettingsURL),
              let hooks = root["hooks"] as? [String: Any] else { return [] }
        var out: [String] = []
        for entry in hooks.values {
            for e in (entry as? [[String: Any]]) ?? [] where isOurs(e) {
                for inner in e["hooks"] as? [[String: Any]] ?? [] {
                    if let c = inner["command"] as? String { out.append(c) }
                }
            }
        }
        return out
    }

    // MARK: The hook's own log

    /// One line per hook run, so "why does nothing show up" has an answer
    /// without a debugger: what came in, and whether it reached the app.
    public static var logURL: URL {
        home.appendingPathComponent("Library/Logs/macon/hook.log")
    }

    public static func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp)  \(line)\n"
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(text.utf8))
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        // Keep it small: past ~4000 lines, drop the oldest half.
        if let all = try? String(contentsOf: url, encoding: .utf8) {
            let lines = all.split(separator: "\n", omittingEmptySubsequences: true)
            if lines.count > 4000 {
                try? (lines.suffix(2000).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// The newest lines, oldest first.
    public static func recentLog(_ count: Int = 5) -> [String] {
        guard let all = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return all.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).map(String.init)
    }

    /// `macon hook <agent> [--port N]` as argv. The subcommand comes right
    /// after `hook`; the port, when it is not the default, after that.
    public static func hookArgv(exe: String, agent: Agent, port: Int?) -> [String] {
        var argv = [exe, "hook", agent.rawValue]
        if let port, port != 8899 { argv += ["--port", String(port)] }
        return argv
    }

    /// The same as one shell line, for Claude's `command` string.
    static func hookCommand(exe: String, agent: Agent, port: Int?) -> String {
        hookArgv(exe: exe, agent: agent, port: port)
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }

    // MARK: Claude Code

    /// `$HOME` when set (a hook runs inside the agent's environment, and tests
    /// point it somewhere harmless), else the account's home.
    static var home: URL {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var claudeSettingsURL: URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    /// The hook events we listen on, and how long each may run. The
    /// permission one is the only long one: it is the hold for the phone.
    static let claudeEvents: [(event: String, timeout: Int)] = [
        ("SessionStart", 10), ("UserPromptSubmit", 10), ("PermissionRequest", 1800),
        ("Notification", 10), ("Stop", 10), ("SessionEnd", 10),
    ]

    public static func claudeInstalled() -> Bool {
        guard let root = readJSON(claudeSettingsURL),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { entry in
            ((entry as? [[String: Any]]) ?? []).contains(where: isOurs)
        }
    }

    /// Add (or refresh) our entries. Throws when the file cannot be written.
    public static func installClaude(exe: String, port: Int? = nil) throws {
        let command = hookCommand(exe: exe, agent: .claude, port: port)
        var root = readJSON(claudeSettingsURL) ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in claudeEvents {
            var entries = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            var entry: [String: Any] = [
                "hooks": [["type": "command", "command": command, "timeout": timeout]],
            ]
            // Claude wants a matcher on the tool-shaped events; empty = every tool.
            if event == "PermissionRequest" { entry["matcher"] = "" }
            entries.append(entry)
            hooks[event] = entries
        }
        root["hooks"] = hooks
        try writeJSON(root, to: claudeSettingsURL)
    }

    public static func uninstallClaude() throws {
        guard var root = readJSON(claudeSettingsURL),
              var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, _) in hooks {
            let kept = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try writeJSON(root, to: claudeSettingsURL)
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        let inner = entry["hooks"] as? [[String: Any]] ?? []
        return inner.contains { ($0["command"] as? String)?.contains("macon") == true
            && ($0["command"] as? String)?.contains(" hook") == true }
    }

    // MARK: Codex

    public static var codexConfigURL: URL {
        home.appendingPathComponent(".codex/config.toml")
    }

    public static func codexInstalled() -> Bool {
        guard let text = try? String(contentsOf: codexConfigURL, encoding: .utf8) else { return false }
        return text.split(separator: "\n").contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("notify") && t.contains("macon") && t.contains("hook")
        }
    }

    /// Codex has one `notify` command. Ours replaces an existing one only if
    /// that one is ours; another tool's notify is left alone and we report it.
    public static func installCodex(exe: String, port: Int? = nil) throws {
        var lines = (try? String(contentsOf: codexConfigURL, encoding: .utf8))?
            .components(separatedBy: "\n") ?? []
        let parts = hookArgv(exe: exe, agent: .codex, port: port).map { "\"\($0)\"" }
        let ours = "notify = [\(parts.joined(separator: ", "))]"
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("notify") }) {
            let existing = lines[i]
            if existing.contains("macon") { lines[i] = ours }
            else { throw HookError.codexNotifyTaken(existing.trimmingCharacters(in: .whitespaces)) }
        } else {
            // Top-level keys must come before any [table]; put it first.
            let insertAt = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
            lines.insert(ours, at: insertAt)
            if lines.last != "" { lines.append("") }      // end the file with a newline
        }
        let dir = codexConfigURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: codexConfigURL, atomically: true, encoding: .utf8)
    }

    public static func uninstallCodex() throws {
        guard let text = try? String(contentsOf: codexConfigURL, encoding: .utf8) else { return }
        let kept = text.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !(t.hasPrefix("notify") && t.contains("macon"))
        }
        // A file that only ever held our line was ours to begin with.
        if kept.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            try? FileManager.default.removeItem(at: codexConfigURL)
            return
        }
        try kept.joined(separator: "\n").write(to: codexConfigURL, atomically: true, encoding: .utf8)
    }

    public enum HookError: Error, LocalizedError {
        case codexNotifyTaken(String)
        case noCLI
        public var errorDescription: String? {
            switch self {
            case .codexNotifyTaken(let line):
                return "Codex already has a notify command (\(line)). Remove it from ~/.codex/config.toml first."
            case .noCLI:
                return "The macon CLI is not installed. brew install macon, then try again."
            }
        }
    }

    // MARK: JSON helpers

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeJSON(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
