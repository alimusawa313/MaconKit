//
//  Hook.swift
//  macon
//
//  `macon hook`: the piece of MacOn that sits inside a coding agent.
//
//    macon hook claude          Claude Code hook (reads the event JSON on stdin)
//    macon hook codex <json>    Codex `notify` command (the event JSON is argv)
//    macon hook install [claude|codex|all] [--port N]
//    macon hook uninstall [claude|codex|all]
//    macon hook status
//
//  The hook posts each moment to the running app's companion server with the
//  CLI's own paired token (it pairs itself, like `macon status`), and exits
//  0 whatever happens: an agent must never be slowed down or broken because
//  MacOn is not running. The one place it lingers is a permission prompt the
//  Mac asked it to hold: then it polls for the phone's answer until one
//  comes, the Mac says somebody is back at the keyboard, or its own deadline
//  passes, and in the last two cases it says nothing so Claude shows the
//  dialog in the terminal as usual.
//

import Foundation
import MaconKit

@MainActor func runHook() async {
    let sub = args.count > 1 ? args[1].lowercased() : "status"
    switch sub {
    case "claude":
        await claudeHook()
    case "codex":
        await codexHook()
    case "install", "uninstall":
        let which = args.count > 2 && !args[2].hasPrefix("--") ? args[2].lowercased() : "all"
        let targets: [CodingAgentHooks.Agent] = which == "all"
            ? CodingAgentHooks.Agent.allCases
            : [CodingAgentHooks.Agent(rawValue: which)].compactMap { $0 }
        guard !targets.isEmpty else { fail("Usage: macon hook \(sub) [claude|codex|all]") }
        let port = option("port").flatMap(Int.init)
        for agent in targets {
            do {
                if sub == "install" {
                    guard let exe = CodingAgentHooks.executable() else {
                        fail(CodingAgentHooks.HookError.noCLI.localizedDescription)
                    }
                    switch agent {
                    case .claude:
                        try CodingAgentHooks.installClaude(exe: exe, port: port)
                        print("✓ Claude Code: hooks written to \(CodingAgentHooks.claudeSettingsURL.path)")
                    case .codex:
                        try CodingAgentHooks.installCodex(exe: exe, port: port)
                        print("✓ Codex: notify set in \(CodingAgentHooks.codexConfigURL.path)")
                    }
                } else {
                    switch agent {
                    case .claude:
                        try CodingAgentHooks.uninstallClaude()
                        print("✓ Claude Code: MacOn hooks removed")
                    case .codex:
                        try CodingAgentHooks.uninstallCodex()
                        print("✓ Codex: MacOn notify removed")
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("✗ \(agent.rawValue): \(error.localizedDescription)\n".utf8))
            }
        }
        if sub == "install" {
            print("Turn on “Let paired devices answer coding agent prompts” in MacOn → Settings → Devices,")
            print("and a new agent session will show up in Macon+ → Code → Agents.")
        }
    case "status":
        print("Claude Code: \(CodingAgentHooks.claudeInstalled() ? "hooked" : "not hooked")  (\(CodingAgentHooks.claudeSettingsURL.path))")
        print("Codex:       \(CodingAgentHooks.codexInstalled() ? "hooked" : "not hooked")  (\(CodingAgentHooks.codexConfigURL.path))")
        if CodingAgentHooks.executable() == nil {
            print("The macon CLI is not on PATH; install it with Homebrew before installing hooks.")
        }
    default:
        fail("Usage: macon hook <install|uninstall|status> [claude|codex|all], or as a hook: macon hook claude")
    }
}

// MARK: - Claude Code

@MainActor private func claudeHook() async {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { return }
    let session = json["session_id"] as? String ?? "claude"
    let cwd = json["cwd"] as? String ?? FileManager.default.currentDirectoryPath
    let name = json["hook_event_name"] as? String ?? ""

    var event = CodingAgentHookEvent(session: session, tool: "claude", cwd: cwd, kind: .working)
    switch name {
    case "SessionStart":
        event.kind = .start
    case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure":
        event.kind = .working
    case "PermissionRequest":
        event.kind = .permission
        let tool = json["tool_name"] as? String ?? "Tool"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        event.prompt = describe(tool: tool, input: toolInput)
    case "Notification":
        event.kind = .notification
        event.message = json["message"] as? String
        if let type = json["notification_type"] as? String {
            // Make the type visible to the hub's keyword check even when the
            // message itself is terse.
            event.message = [event.message, type.replacingOccurrences(of: "_", with: " ")]
                .compactMap { $0 }.joined(separator: " · ")
        }
    case "Stop", "SubagentStop":
        guard name == "Stop" else { return }      // a subagent's turn is not "done"
        event.kind = .stop
        if let path = json["transcript_path"] as? String {
            event.message = lastAssistantText(transcript: path)
        }
    case "SessionEnd":
        event.kind = .end
    default:
        return
    }

    guard let reply = await post(event) else { return }

    // A permission the Mac wants held for the phone: poll for the answer.
    guard event.kind == .permission, reply.hold, let seq = reply.seq else { return }
    if let decision = reply.decision { emitClaudeDecision(decision); return }

    let minutes = Double(option("hold-minutes") ?? "") ?? 25
    let deadline = Date().addingTimeInterval(minutes * 60)
    while Date() < deadline {
        let path = "coding-agents/\(session)/decision?seq=\(seq)&wait=10"
        guard let (code, data) = try? await Remote.request(path), code == 200,
              let poll = try? CompanionJSON.decoder.decode(CodingAgentHookResponse.self, from: data) else {
            return                                 // server gone: the Mac shows the dialog
        }
        if let decision = poll.decision { emitClaudeDecision(decision); return }
        if !poll.hold { return }                   // somebody is back at the Mac
    }
}

/// Claude's PermissionRequest output: allow, or deny with a reason.
private func emitClaudeDecision(_ decision: CompanionCodingAgentDecisionDTO) {
    var inner: [String: Any] = ["behavior": decision.allow ? "allow" : "deny"]
    if !decision.allow {
        inner["message"] = decision.message ?? "Denied from a paired device via MacOn."
    }
    let out: [String: Any] = [
        "hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": inner,
        ],
    ]
    if let data = try? JSONSerialization.data(withJSONObject: out) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

/// One line the phone can act on: the command, the file, the URL.
private func describe(tool: String, input: [String: Any]) -> CodingAgentHookEvent.Prompt {
    func str(_ key: String) -> String? {
        (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var summary: String
    var detail: String?
    switch tool {
    case "Bash":
        summary = str("command") ?? ""
        detail = str("description")
    case "Edit", "MultiEdit", "Write", "NotebookEdit", "Read":
        summary = str("file_path") ?? str("notebook_path") ?? ""
        if tool == "Write" { detail = str("content") }
        else if tool == "Edit" { detail = str("new_string") }
    case "WebFetch":
        summary = str("url") ?? ""
        detail = str("prompt")
    case "WebSearch":
        summary = str("query") ?? ""
    case "Agent", "Task":
        summary = str("description") ?? str("prompt") ?? ""
        detail = str("prompt")
    default:
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            summary = text
        } else { summary = tool }
    }
    if summary.isEmpty { summary = tool }
    // MCP tools arrive as mcp__server__tool; show the tail.
    let shownTool = tool.hasPrefix("mcp__")
        ? tool.split(separator: "_", omittingEmptySubsequences: true).last.map(String.init) ?? tool
        : tool
    return CodingAgentHookEvent.Prompt(tool: shownTool,
                                       summary: String(summary.prefix(400)),
                                       detail: detail.map { String($0.prefix(1200)) })
}

/// The agent's last words, from the tail of its transcript (JSONL, one
/// message per line). Only the last 64 KB are read; a final reply is short.
private func lastAssistantText(transcript path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let window: UInt64 = 64 * 1024
    let start = size > window ? size - window : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n").reversed() {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { continue }
        let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty { return String(joined.prefix(500)) }
    }
    return nil
}

// MARK: - Codex

/// Codex calls `notify` with one JSON argument per event. Only the end of a
/// turn is reported today: `{"type":"agent-turn-complete", "turn-id":…,
/// "last-assistant-message":…, "input-messages":[…]}`.
@MainActor private func codexHook() async {
    // Codex appends the JSON as the last argument, after any --port we baked in.
    guard args.count > 2, let raw = args.last, raw.hasPrefix("{"),
          let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { return }
    let cwd = json["cwd"] as? String ?? FileManager.default.currentDirectoryPath
    let thread = json["thread-id"] as? String ?? json["thread_id"] as? String
    let session = "codex:" + (thread ?? String(cwd.hashValue, radix: 36))
    var event = CodingAgentHookEvent(session: session, tool: "codex", cwd: cwd, kind: .stop)
    switch json["type"] as? String ?? "" {
    case "agent-turn-complete":
        event.kind = .stop
        event.message = (json["last-assistant-message"] as? String)
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)) }
    default:
        return
    }
    _ = await post(event)
}

// MARK: - Transport

/// POST the moment; nil when the app is not there (which is fine).
private func post(_ event: CodingAgentHookEvent) async -> CodingAgentHookResponse? {
    guard let body = try? CompanionJSON.encoder.encode(event),
          let (code, data) = try? await Remote.request("coding-agents/hook", method: "POST", body: body),
          code == 200 else { return nil }
    return try? CompanionJSON.decoder.decode(CodingAgentHookResponse.self, from: data)
}
