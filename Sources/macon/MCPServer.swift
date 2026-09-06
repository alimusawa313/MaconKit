//
//  MCPServer.swift
//  macon
//
//  `macon mcp` — this Mac as an MCP server, so Claude (Desktop, Code, or
//  anything else that speaks the protocol) can look at builds, start them,
//  run Flows and read and write files on it.
//
//  It is a client of the companion server, not a second way in. Every tool
//  here is one of the HTTP calls a paired iPhone makes, with the same bearer
//  token and the same gates on the Mac's side: files need "Code (files &
//  terminal)" switched on there, pipelines need the runner, and a refusal
//  comes back as the tool's error rather than being worked around. So
//  turning this on grants an assistant exactly what a paired phone already
//  has, and switching a toggle off in MacOn takes it away from both.
//
//  Transport is stdio with newline-delimited JSON-RPC 2.0, which is what a
//  local MCP client launches. stdout carries protocol only; anything worth
//  saying to a human goes to stderr, because a stray print on stdout breaks
//  the framing.
//
//  Wire it into Claude Desktop or Claude Code as a command-type server:
//      { "command": "macon", "args": ["mcp"] }
//  For another Mac, add "--host runner.example.id" after "mcp".
//

import Foundation
import MaconKit

// MARK: - JSON helpers

/// Minimal JSON value, so responses can be assembled without a type per shape.
indirect enum JSON: Encodable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:            try c.encodeNil()
        case .bool(let v):     try c.encode(v)
        case .int(let v):      try c.encode(v)
        case .double(let v):   try c.encode(v)
        case .string(let v):   try c.encode(v)
        case .array(let v):    try c.encode(v)
        case .object(let v):   try c.encode(v)
        }
    }

    static func from(_ any: Any) -> JSON {
        switch any {
        case is NSNull:            return .null
        case let v as Bool:        return .bool(v)
        case let v as Int:         return .int(v)
        case let v as Double:      return .double(v)
        case let v as String:      return .string(v)
        case let v as [Any]:       return .array(v.map(JSON.from))
        case let v as [String: Any]:
            return .object(v.mapValues(JSON.from))
        default:                   return .string(String(describing: any))
        }
    }
}

// MARK: - The server

enum MCPServer {
    /// The revision of the protocol this speaks.
    static let protocolVersion = "2025-06-18"

    static func run() async {
        note("macon mcp: talking to \(Remote.host)")
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                send(error: nil, code: -32700, message: "Not JSON")
                continue
            }
            await handle(message)
        }
    }

    private static func handle(_ message: [String: Any]) async {
        let method = message["method"] as? String ?? ""
        // A notification has no id and takes no reply, ever.
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            reply(id, .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object([
                    "name": .string("macon"),
                    "title": .string("MacOn"),
                    "version": .string(maconVersion),
                ]),
                "instructions": .string("""
                    This is one Mac running MacOn: its CI pipelines, its builds and \
                    its home folder. Read with mac_status, list_pipelines, \
                    list_builds, build_log, list_files and read_file. Change things \
                    with run_pipeline, cancel_build, run_flow and write_file. \
                    Paths are home-relative and start with "~". A tool that answers \
                    "switched off on the Mac" means a toggle in MacOn's settings \
                    has to be turned on by the person at the Mac; do not try to \
                    work around it.
                    """),
            ]))

        case "notifications/initialized", "notifications/cancelled":
            break   // nothing to answer

        case "ping":
            reply(id, .object([:]))

        case "tools/list":
            reply(id, .object(["tools": .array(Tools.all.map(\.schema))]))

        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let tool = Tools.all.first(where: { $0.name == name }) else {
                send(error: id, code: -32602, message: "No tool called \(name)")
                return
            }
            do {
                let text = try await tool.run(arguments)
                reply(id, .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                    "isError": .bool(false),
                ]))
            } catch {
                // A tool failure is a result, not a protocol error: the model
                // should read it and decide, not have the call vanish.
                reply(id, .object([
                    "content": .array([.object([
                        "type": .string("text"),
                        "text": .string(describe(error)),
                    ])]),
                    "isError": .bool(true),
                ]))
            }

        default:
            if id != nil { send(error: id, code: -32601, message: "Unknown method \(method)") }
        }
    }

    // MARK: Framing

    private static func reply(_ id: Any?, _ result: JSON) {
        guard let id else { return }
        write(["jsonrpc": .string("2.0"), "id": JSON.from(id), "result": result])
    }

    private static func send(error id: Any?, code: Int, message: String) {
        guard let id else { return }
        write(["jsonrpc": .string("2.0"), "id": JSON.from(id),
               "error": .object(["code": .int(code), "message": .string(message)])])
    }

    private static func write(_ payload: [String: JSON]) {
        guard let data = try? JSONEncoder().encode(payload),
              var text = String(data: data, encoding: .utf8) else { return }
        text += "\n"
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    /// Human-facing chatter, kept off the protocol stream.
    static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func describe(_ error: Error) -> String {
        if let cli = error as? CLIError { return cli.message }
        return error.localizedDescription
    }
}

// MARK: - Tools

struct MCPTool {
    let name: String
    let title: String
    let description: String
    /// JSON Schema for the arguments, as a plain dictionary.
    let input: [String: JSON]
    let required: [String]
    let readOnly: Bool
    let run: ([String: Any]) async throws -> String

    var schema: JSON {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(input),
                "required": .array(required.map(JSON.string)),
            ]),
            "annotations": .object([
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(!readOnly),
            ]),
        ])
    }
}

private func str(_ description: String) -> JSON {
    .object(["type": .string("string"), "description": .string(description)])
}

private func int(_ description: String) -> JSON {
    .object(["type": .string("integer"), "description": .string(description)])
}

enum Tools {
    static let all: [MCPTool] = [
        macStatus, listPipelines, runPipeline, listBuilds, buildLog, cancelBuild,
        listFlows, runFlow, listFiles, readFile, writeFile,
    ]

    // MARK: The Mac itself

    static let macStatus = MCPTool(
        name: "mac_status",
        title: "Mac status",
        description: "How the Mac is doing: locked or not, CPU, memory, disk, battery, thermal state and uptime.",
        input: [:], required: [], readOnly: true) { _ in
            let system: CompanionSystemDTO = try await Remote.getJSON("system")
            let power: CompanionPowerDTO? = try? await Remote.getJSON("power")
            var lines = [
                "CPU: \(pct(system.cpu)) of the machine",
                "Memory: \(gb(system.memUsed)) of \(gb(system.memTotal))",
                "Disk free: \(gb(system.diskFree)) of \(gb(system.diskTotal))",
                "Thermal: \(system.thermal)",
                "Uptime: \(duration(system.uptime))",
            ]
            if let battery = system.battery {
                lines.append("Battery: \(pct(battery))\(system.charging == true ? ", charging" : "")")
            }
            lines.append("Power: \(system.onAc ? "on AC" : "on battery")")
            if let power {
                lines.append("Screen: \(power.locked ? "locked" : "unlocked")\(power.displayAsleep ? ", display asleep" : "")")
            }
            return lines.joined(separator: "\n")
        }

    // MARK: Pipelines and builds

    static let listPipelines = MCPTool(
        name: "list_pipelines",
        title: "List pipelines",
        description: "Every CI pipeline configured on the Mac, with its repo, branch and current state.",
        input: [:], required: [], readOnly: true) { _ in
            let resp: CompanionPipelinesDTO = try await Remote.getJSON("pipelines")
            guard !resp.pipelines.isEmpty else { return "No pipelines configured." }
            return resp.pipelines.map { p in
                let watching = (p.isWatching ?? false) ? "watching" : "idle"
                let building = (p.isBuilding ?? false) ? ", building now" : ""
                return "\(p.name)  [\(p.id)]\n  \(p.provider) \(p.workspace)/\(p.repoSlug) @ \(p.branch)\n  \(watching)\(building), last: \(p.state ?? "unknown")"
            }.joined(separator: "\n")
        }

    static let runPipeline = MCPTool(
        name: "run_pipeline",
        title: "Start a build",
        description: "Build a pipeline's current head on the Mac now. Takes the pipeline's id or the start of its name.",
        input: ["pipeline": str("Pipeline id, or enough of its name to be unambiguous.")],
        required: ["pipeline"], readOnly: false) { args in
            let needle = try requireString(args, "pipeline")
            let resp: CompanionPipelinesDTO = try await Remote.getJSON("pipelines")
            guard let match = resolvePipeline(needle, in: resp.pipelines) else {
                throw CLIError("No pipeline matches \"\(needle)\". Try list_pipelines.")
            }
            let (code, _) = try await Remote.request("pipelines/\(match.id)/run", method: "POST")
            guard code == 200 else { throw CLIError(Remote.httpHint(code)) }
            return "Started a build of \(match.name) (\(match.workspace)/\(match.repoSlug) @ \(match.branch))."
        }

    static let listBuilds = MCPTool(
        name: "list_builds",
        title: "List builds",
        description: "Recent builds on the Mac, newest first, with their status and which step a running one is on.",
        input: ["limit": int("How many to return. Default 15.")],
        required: [], readOnly: true) { args in
            let limit = (args["limit"] as? Int) ?? 15
            let resp: CompanionBuildsDTO = try await Remote.getJSON("builds")
            guard !resp.builds.isEmpty else { return "No builds yet on \(resp.runnerName)." }
            return resp.builds.prefix(max(1, limit)).map { b in
                var line = "\(b.status.uppercased())  \(b.repo) @ \(b.branch)  \(b.commit)  [\(b.id)]"
                if let step = b.currentStep, !step.isEmpty { line += "\n  at: \(step)" }
                if let started = b.startedAt {
                    let end = b.finishedAt ?? Date()
                    line += "\n  took \(duration(end.timeIntervalSince(started)))"
                }
                return line
            }.joined(separator: "\n")
        }

    static let buildLog = MCPTool(
        name: "build_log",
        title: "Read a build log",
        description: "Log lines for one build. Use the build id from list_builds. Returns the tail, which is where a failure is.",
        input: [
            "build": str("The build id, e.g. \"<pipeline>~live\" for the one in flight."),
            "tail": int("How many lines from the end. Default 120."),
        ],
        required: ["build"], readOnly: true) { args in
            let id = try requireString(args, "build")
            let tail = (args["tail"] as? Int) ?? 120
            let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? id
            let lines: [CompanionLogDTO] = try await Remote.getJSON("builds/\(encoded)/logs?after=-1")
            guard !lines.isEmpty else { return "No log lines for \(id)." }
            let slice = lines.suffix(max(1, tail))
            return slice.map { $0.level == "error" ? "! \($0.text)" : $0.text }.joined(separator: "\n")
        }

    static let cancelBuild = MCPTool(
        name: "cancel_build",
        title: "Cancel a build",
        description: "Stop the build that is currently running, by its id from list_builds.",
        input: ["build": str("The build id.")],
        required: ["build"], readOnly: false) { args in
            let id = try requireString(args, "build")
            let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? id
            let (code, _) = try await Remote.request("builds/\(encoded)/cancel", method: "POST")
            guard code == 200 else {
                throw CLIError(code == 409 ? "That build is not the one running." : Remote.httpHint(code))
            }
            return "Cancelled \(id)."
        }

    // MARK: Flows

    static let listFlows = MCPTool(
        name: "list_flows",
        title: "List Flows",
        description: "The automations (Flows) saved on the Mac.",
        input: [:], required: [], readOnly: true) { _ in
            struct Reply: Decodable { var flows: [Named] }
            struct Named: Decodable { var id: String; var name: String }
            let resp: Reply = try await Remote.getJSON("flows")
            guard !resp.flows.isEmpty else { return "No Flows saved." }
            return resp.flows.map { "\($0.name)  [\($0.id)]" }.joined(separator: "\n")
        }

    static let runFlow = MCPTool(
        name: "run_flow",
        title: "Run a Flow",
        description: "Run one of the Mac's Flows. Takes the Flow's id.",
        input: ["flow": str("The Flow's id, from list_flows.")],
        required: ["flow"], readOnly: false) { args in
            let id = try requireString(args, "flow")
            let (code, _) = try await Remote.request("flows/\(id)/run", method: "POST", body: Data("{}".utf8))
            guard code == 200 else { throw CLIError(Remote.httpHint(code)) }
            return "Started Flow \(id)."
        }

    // MARK: Files

    static let listFiles = MCPTool(
        name: "list_files",
        title: "List a folder",
        description: "A folder inside the Mac's home directory. Paths are home-relative and start with \"~\". Needs \"Code (files & terminal)\" on in MacOn.",
        input: ["path": str("Folder path, e.g. \"~/Projects\". Defaults to the home directory.")],
        required: [], readOnly: true) { args in
            let path = (args["path"] as? String) ?? "~"
            let listing: CompanionFileListDTO = try await Remote.getJSON("files/list?path=\(query(path))")
            guard !listing.entries.isEmpty else { return "\(listing.path) is empty." }
            let rows = listing.entries.map { e in
                e.dir ? "\(e.name)/" : "\(e.name)  (\(gb(e.size)))"
            }
            return "\(listing.path)\n" + rows.joined(separator: "\n")
        }

    static let readFile = MCPTool(
        name: "read_file",
        title: "Read a file",
        description: "A text file from the Mac's home directory, as UTF-8. Binary files are refused rather than mangled.",
        input: ["path": str("File path, e.g. \"~/Projects/App/README.md\".")],
        required: ["path"], readOnly: true) { args in
            let path = try requireString(args, "path")
            let (code, data) = try await Remote.request("files/blob?path=\(query(path))")
            guard code == 200 else { throw CLIError(Remote.httpHint(code)) }
            guard let text = String(data: data, encoding: .utf8) else {
                throw CLIError("\(path) is not UTF-8 text (\(gb(Int64(data.count))) of binary).")
            }
            return text
        }

    static let writeFile = MCPTool(
        name: "write_file",
        title: "Write a file",
        description: "Write UTF-8 text to a path in the Mac's home directory, creating the file if it is not there. Replaces the whole file.",
        input: [
            "path": str("File path, e.g. \"~/notes.md\"."),
            "content": str("The complete new contents."),
        ],
        required: ["path", "content"], readOnly: false) { args in
            let path = try requireString(args, "path")
            let content = try requireString(args, "content")
            let (code, _) = try await Remote.request("files/blob?path=\(query(path))", method: "PUT",
                                                     body: Data(content.utf8))
            guard code == 200 else { throw CLIError(Remote.httpHint(code)) }
            return "Wrote \(content.utf8.count) bytes to \(path)."
        }

    // MARK: Small helpers

    private static func requireString(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else {
            throw CLIError("Missing \"\(key)\".")
        }
        return value
    }

    private static func query(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? s
    }

    private static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private static func gb(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        let h = s / 3600
        if h < 24 { return "\(h)h \((s % 3600) / 60)m" }
        return "\(h / 24)d \(h % 24)h"
    }
}
