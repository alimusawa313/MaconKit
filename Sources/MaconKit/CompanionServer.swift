//
//  CompanionServer.swift
//  MaconKit
//
//  HTTP + WebSocket server for the companion app. Zero dependencies
//  (Network.framework), same style as WebhookServer. Routes:
//
//    POST /pair                 (no auth)  device-code → token
//    GET  /builds               (Bearer)   build list
//    GET  /builds/{id}          (Bearer)   one build
//    POST /builds/{id}/rerun    (Bearer)   trigger a fresh run of its pipeline
//    POST /builds/{id}/cancel   (Bearer)   stop it if it's building
//    WS   /builds/{id}/logs     (Bearer)   live log tail
//    GET  /builds/{id}/logs?after=N (Bearer)  log lines as JSON (for the CLI)
//    GET  /metrics              (Bearer)   Prometheus text exposition
//    GET  /pipelines            (Bearer)   configured pipelines + live state
//    POST /pipelines            (Bearer)   create a pipeline
//    PUT  /pipelines/{id}       (Bearer)   update a pipeline's config
//    DELETE /pipelines/{id}     (Bearer)   remove a pipeline
//    POST /pipelines/{id}/watch|unwatch|run  (Bearer)  runner controls
//    GET  /windows              (Bearer)   open Mac windows (CompactOS picker)
//    POST /compact/open         (Bearer)   open/fit an app window for CompactOS
//    POST /agent/task           (Bearer)   dictate a task; the Mac drives itself
//    WS   /agent/{id}/events    (Bearer)   agent step feed (JSON text frames)
//    POST /agent/{id}/stop      (Bearer)   abort an agent run
//    POST /agent/{id}/decision  (Bearer)   approve/skip an awaiting agent step
//    WS   /screen?window={id}   (Bearer)   stream one window instead of the display
//
//  Meant to sit behind a cloudflared tunnel (which terminates TLS), so a
//  headless EC2 Mac is reachable at a stable https/wss URL.
//

import Foundation
import Network
import CryptoKit

public final class CompanionServer: @unchecked Sendable {

    public typealias Authorize = @Sendable (String) -> Bool
    public typealias Pair = @Sendable (_ code: String, _ device: String) async -> CompanionPairResponseDTO?
    public typealias Builds = @Sendable () async -> CompanionBuildsDTO
    public typealias Build = @Sendable (_ id: String) async -> CompanionBuildDTO?
    public typealias LogsSince = @Sendable (_ id: String, _ afterSeq: Int) async -> [CompanionLogDTO]
    /// Run a build action ("rerun" | "cancel"); returns whether it applied.
    public typealias BuildActionFn = @Sendable (_ id: String, _ action: String) async -> Bool

    /// Pipeline management callbacks (nil = the /pipelines routes 404, e.g. a
    /// headless CLI running from a fixed config file).
    public struct PipelineOps: Sendable {
        public var list: @Sendable () async -> CompanionPipelinesDTO
        public var create: @Sendable (Data) async -> Bool
        public var update: @Sendable (String, Data) async -> Bool
        public var remove: @Sendable (String) async -> Bool
        public var watch: @Sendable (String, Bool) async -> Bool
        public var run: @Sendable (String) async -> Bool
        /// Provider lookups for the editor's pickers (provider, workspace[, repo]).
        public var repos: @Sendable (String, String) async -> [String]?
        public var branches: @Sendable (String, String, String) async -> [String]?

        public init(list: @escaping @Sendable () async -> CompanionPipelinesDTO,
                    create: @escaping @Sendable (Data) async -> Bool,
                    update: @escaping @Sendable (String, Data) async -> Bool,
                    remove: @escaping @Sendable (String) async -> Bool,
                    watch: @escaping @Sendable (String, Bool) async -> Bool,
                    run: @escaping @Sendable (String) async -> Bool,
                    repos: @escaping @Sendable (String, String) async -> [String]? = { _, _ in nil },
                    branches: @escaping @Sendable (String, String, String) async -> [String]? = { _, _, _ in nil }) {
            self.list = list; self.create = create; self.update = update
            self.remove = remove; self.watch = watch; self.run = run
            self.repos = repos; self.branches = branches
        }
    }

    /// Native file access for the companion's Code editor (nil = the /code
    /// routes 404). Every op is gated by the app's "allow code" toggle.
    public struct CodeOps: Sendable {
        public var list: @Sendable (String) async -> CompanionCodeListDTO?
        public var read: @Sendable (String) async -> CompanionCodeFileDTO?
        /// Returns false when the write was refused (bad path, not text).
        public var write: @Sendable (String, String) async -> Bool
        /// Open the path in the Mac's editor (VS Code); false when refused.
        public var open: @Sendable (String) async -> Bool
        /// Xcode projects/workspaces on the Mac (nil = refused/off).
        public var xcodeProjects: (@Sendable () async -> CompanionCodeListDTO?)?
        /// A project's schemes, via xcodebuild (nil = refused/failed).
        public var xcodeSchemes: (@Sendable (String) async -> CompanionListDTO?)?
        /// xcodebuild destination strings (the Mac + available simulators).
        public var xcodeDestinations: (@Sendable () async -> CompanionListDTO?)?

        public init(list: @escaping @Sendable (String) async -> CompanionCodeListDTO?,
                    read: @escaping @Sendable (String) async -> CompanionCodeFileDTO?,
                    write: @escaping @Sendable (String, String) async -> Bool,
                    open: @escaping @Sendable (String) async -> Bool,
                    xcodeProjects: (@Sendable () async -> CompanionCodeListDTO?)? = nil,
                    xcodeSchemes: (@Sendable (String) async -> CompanionListDTO?)? = nil,
                    xcodeDestinations: (@Sendable () async -> CompanionListDTO?)? = nil) {
            self.list = list; self.read = read; self.write = write; self.open = open
            self.xcodeProjects = xcodeProjects; self.xcodeSchemes = xcodeSchemes
            self.xcodeDestinations = xcodeDestinations
        }
    }

    /// A live shell on the Mac for the companion's Code terminal (nil = the
    /// /term route 404s). One PTY session per WebSocket; raw output bytes
    /// stream out as binary frames, input/resizes arrive as JSON text frames.
    public struct TermOps: Sendable {
        /// Start a session: id, working directory, and the sink for output
        /// bytes. False = refused (feature off).
        public var start: @Sendable (String, String?, @escaping @Sendable (Data) -> Void) async -> Bool
        public var input: @Sendable (String, Data) async -> Void
        public var resize: @Sendable (String, Int, Int) async -> Void
        public var close: @Sendable (String) async -> Void

        public init(start: @escaping @Sendable (String, String?, @escaping @Sendable (Data) -> Void) async -> Bool,
                    input: @escaping @Sendable (String, Data) async -> Void,
                    resize: @escaping @Sendable (String, Int, Int) async -> Void,
                    close: @escaping @Sendable (String) async -> Void) {
            self.start = start; self.input = input; self.resize = resize; self.close = close
        }
    }

    /// The Flows feature (visual automations the companion edits, the Mac
    /// runs). Payloads stay opaque Data — the app owns the shapes — so the
    /// routes are pure plumbing. nil ops = the /flows routes 404; a closure
    /// returning nil = refused (403, feature off) or unknown id (404).
    public struct FlowOps: Sendable {
        public var list: @Sendable () async -> Data?
        public var save: @Sendable (Data) async -> Bool
        public var remove: @Sendable (String) async -> Bool
        /// Start a run: flow id + request body → {runId} JSON.
        public var run: @Sendable (String, Data) async -> Data?
        /// A flow's finished runs, newest first.
        public var runs: @Sendable (String) async -> Data?
        /// One run — live state while executing, else from history.
        public var runDetail: @Sendable (String) async -> Data?
        public var cancel: @Sendable (String) async -> Bool

        public init(list: @escaping @Sendable () async -> Data?,
                    save: @escaping @Sendable (Data) async -> Bool,
                    remove: @escaping @Sendable (String) async -> Bool,
                    run: @escaping @Sendable (String, Data) async -> Data?,
                    runs: @escaping @Sendable (String) async -> Data?,
                    runDetail: @escaping @Sendable (String) async -> Data?,
                    cancel: @escaping @Sendable (String) async -> Bool) {
            self.list = list; self.save = save; self.remove = remove
            self.run = run; self.runs = runs; self.runDetail = runDetail
            self.cancel = cancel
        }
    }

    /// The Mac-side agent: dictate a task, the Mac drives itself against the
    /// accessibility tree (nil = the /agent routes 404). Gated by the app's
    /// "allow control" toggle — a task IS remote control.
    public struct AgentOps: Sendable {
        /// Start a task. Nil = refused (control off) → 409.
        public var start: @Sendable (CompanionAgentTaskRequestDTO) async -> CompanionAgentStartResponseDTO?
        /// Step-feed events after a seq (the WS poll loop + the JSON route).
        public var eventsSince: @Sendable (String, Int) async -> [CompanionAgentEventDTO]
        /// Abort a run. False = unknown agent id.
        public var stop: @Sendable (String) async -> Bool
        /// Approve/skip the step an `approval` event named.
        public var decision: @Sendable (String, Int, Bool) async -> Bool

        public init(start: @escaping @Sendable (CompanionAgentTaskRequestDTO) async -> CompanionAgentStartResponseDTO?,
                    eventsSince: @escaping @Sendable (String, Int) async -> [CompanionAgentEventDTO],
                    stop: @escaping @Sendable (String) async -> Bool,
                    decision: @escaping @Sendable (String, Int, Bool) async -> Bool) {
            self.start = start; self.eventsSince = eventsSince
            self.stop = stop; self.decision = decision
        }
    }

    /// One inbound terminal frame: keystrokes (base64) or a resize.
    private struct TermInbound: Decodable {
        let t: String            // "in" | "size"
        let d: String?           // base64 input bytes
        let c: Int?              // cols
        let r: Int?              // rows
    }

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "macon.companion")
    private var listener: NWListener?

    private let authorize: Authorize
    private let pair: Pair
    private let builds: Builds
    private let build: Build
    private let logsSince: LogsSince
    private let buildAction: BuildActionFn?
    private let pipelineOps: PipelineOps?
    /// Prometheus text for GET /metrics (nil disables the route).
    private let metrics: (@Sendable () async -> String)?
    private let onLog: @Sendable (String) -> Void

    /// Optional H.264 screen streaming. Nil disables the /screen route (e.g. the
    /// headless CLI, which has no display to capture).
    private let screen: ScreenBroadcaster?
    /// Optional remote-control sink. Nil disables the /control route.
    private let control: (@Sendable (ControlEvent) -> Void)?
    /// Optional installed-app catalog (the app supplies one with icons). Falls
    /// back to a Foundation-only, icon-less enumeration.
    private let apps: (@Sendable () -> CompanionAppsDTO)?
    /// CompactOS: enumerate the Mac's open windows (nil disables /windows).
    private let windows: (@Sendable () async -> CompanionWindowsDTO)?
    /// CompactOS: open/focus an app and fit its window to the device. Returns
    /// nil when refused (e.g. remote control disabled) → 409.
    private let compactOpen: (@Sendable (CompanionCompactOpenRequestDTO) async -> CompanionCompactOpenResponseDTO?)?
    /// CompactOS: point the screen stream at one window (nil = whole display).
    /// Called on every /screen connect — last viewer wins.
    private let screenTarget: (@Sendable (UInt32?) -> Void)?
    /// Power: reachability/wake/unlock. `power` reports state; `wake` lights the
    /// display; `unlock` types the stored password (returns whether it applied).
    private let power: (@Sendable () async -> CompanionPowerDTO)?
    private let wake: (@Sendable () async -> Void)?
    private let unlock: (@Sendable () async -> Bool)?
    /// Set the Mac's privacy curtain on/off (universal screen blocker); returns
    /// whether it ended up raised.
    private let privacy: (@Sendable (_ on: Bool) async -> Bool)?
    /// Lock the Mac's screen (login window). Returns whether it applied.
    private let lock: (@Sendable () async -> Bool)?
    /// AI (local Ollama proxy). `aiModels` returns the encoded model list, or
    /// nil when the local model host is unreachable/disabled → 503. `aiChat`
    /// streams the reply: it forwards the request body to the local host and
    /// calls `emit` once per NDJSON line, which we relay to the client.
    private let aiModels: (@Sendable () async -> Data?)?
    private let aiChat: (@Sendable (_ body: Data, _ emit: @escaping @Sendable (Data) -> Void) async -> Void)?
    private let codeOps: CodeOps?
    private let termOps: TermOps?
    private let flowOps: FlowOps?
    /// Fleet: the paired devices and their liveness, for the device map.
    /// Payload is opaque Data (the app owns the shape); nil op = 404.
    private let devices: (@Sendable () async -> Data?)?
    /// Push: a device hands the Mac its APNs token so build alerts reach it.
    /// The bearer token identifies which paired device; body is opaque.
    private let apnsRegister: (@Sendable (_ bearer: String, _ body: Data) async -> Bool)?
    /// The dictate-to-drive Mac agent (nil disables the /agent routes).
    private let agentOps: AgentOps?

    private static let controlDecoder = JSONDecoder()

    public init(port: UInt16,
                authorize: @escaping Authorize,
                pair: @escaping Pair,
                builds: @escaping Builds,
                build: @escaping Build,
                logsSince: @escaping LogsSince,
                buildAction: BuildActionFn? = nil,
                pipelineOps: PipelineOps? = nil,
                metrics: (@Sendable () async -> String)? = nil,
                screen: ScreenBroadcaster? = nil,
                control: (@Sendable (ControlEvent) -> Void)? = nil,
                apps: (@Sendable () -> CompanionAppsDTO)? = nil,
                windows: (@Sendable () async -> CompanionWindowsDTO)? = nil,
                compactOpen: (@Sendable (CompanionCompactOpenRequestDTO) async -> CompanionCompactOpenResponseDTO?)? = nil,
                screenTarget: (@Sendable (UInt32?) -> Void)? = nil,
                power: (@Sendable () async -> CompanionPowerDTO)? = nil,
                wake: (@Sendable () async -> Void)? = nil,
                unlock: (@Sendable () async -> Bool)? = nil,
                privacy: (@Sendable (_ on: Bool) async -> Bool)? = nil,
                lock: (@Sendable () async -> Bool)? = nil,
                aiModels: (@Sendable () async -> Data?)? = nil,
                aiChat: (@Sendable (_ body: Data, _ emit: @escaping @Sendable (Data) -> Void) async -> Void)? = nil,
                codeOps: CodeOps? = nil,
                termOps: TermOps? = nil,
                flowOps: FlowOps? = nil,
                devices: (@Sendable () async -> Data?)? = nil,
                apnsRegister: (@Sendable (_ bearer: String, _ body: Data) async -> Bool)? = nil,
                agentOps: AgentOps? = nil,
                onLog: @escaping @Sendable (String) -> Void) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 8899
        self.authorize = authorize
        self.pair = pair
        self.builds = builds
        self.build = build
        self.logsSince = logsSince
        self.buildAction = buildAction
        self.pipelineOps = pipelineOps
        self.metrics = metrics
        self.screen = screen
        self.control = control
        self.apps = apps
        self.windows = windows
        self.compactOpen = compactOpen
        self.screenTarget = screenTarget
        self.power = power
        self.wake = wake
        self.unlock = unlock
        self.privacy = privacy
        self.lock = lock
        self.aiModels = aiModels
        self.aiChat = aiChat
        self.codeOps = codeOps
        self.termOps = termOps
        self.flowOps = flowOps
        self.devices = devices
        self.apnsRegister = apnsRegister
        self.agentOps = agentOps
        self.onLog = onLog
    }

    // MARK: Lifecycle

    public func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            // Latency-tuned TCP: no Nagle batching, and QoS-tagged as
            // interactive video so Wi-Fi (WMM) prioritizes our packets.
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            // Detect a dead peer promptly. Without this, a companion that
            // vanishes uncleanly (app killed, Wi-Fi dropped, Mac slept) leaves
            // its socket "open" — and a live /screen viewer keeps the capture +
            // H.264 encoder running full-tilt to nobody, pinning the CPU. With
            // keepalive the OS errors the connection in ~20s, so drainClient
            // removes the viewer and capture stops on its own.
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10          // start probing after 10s idle
            tcp.keepaliveInterval = 5       // probe every 5s
            tcp.keepaliveCount = 2          // give up after 2 misses (~20s)
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            params.serviceClass = .interactiveVideo
            do {
                let l = try NWListener(using: params, on: port)
                l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                l.start(queue: queue)
                listener = l
                onLog("📡 Companion server listening on :\(port.rawValue)")
            } catch {
                onLog("✗ Companion couldn't bind port \(port.rawValue): \(error.localizedDescription)")
            }
        }
    }

    public func stop() {
        queue.async { [self] in listener?.cancel(); listener = nil }
    }

    // MARK: Request lifecycle

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    /// Accumulate until the full header block (and any POST body) has arrived.
    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var acc = buffer
            if let data, !data.isEmpty { acc.append(data) }
            guard let sep = acc.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil { conn.cancel() } else { self.readRequest(conn, buffer: acc) }
                return
            }
            let header = String(data: acc.subdata(in: acc.startIndex..<sep.lowerBound), encoding: .utf8) ?? ""
            let contentLength = self.headerInt(header, "content-length") ?? 0
            let have = acc.distance(from: sep.upperBound, to: acc.endIndex)
            if have < contentLength && !isComplete && error == nil {
                self.readRequest(conn, buffer: acc); return
            }
            let body = acc.subdata(in: sep.upperBound..<acc.endIndex)
            self.route(conn, header: header, body: body)
        }
    }

    private func route(_ conn: NWConnection, header: String, body: Data) {
        let requestLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map { $0.uppercased() } ?? ""
        let rawPath = parts.count > 1 ? String(parts[1]) : "/"
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
        let segs = path.split(separator: "/").map(String.init)
        // ?key=value query params (percent-decoded).
        let query: [String: String] = {
            guard let q = rawPath.split(separator: "?").dropFirst().first else { return [:] }
            var out: [String: String] = [:]
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                out[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
            return out
        }()

        // POST /pair — the only unauthenticated route.
        if method == "POST", path == "/pair" {
            Task {
                guard let req = try? CompanionJSON.decoder.decode(CompanionPairRequestDTO.self, from: body),
                      let resp = await self.pair(req.code, req.deviceName) else {
                    self.respond(conn, "401 Unauthorized", json: nil); return
                }
                self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(resp))
            }
            return
        }

        // Everything else needs a valid bearer token.
        guard let token = bearer(header), authorize(token) else {
            respond(conn, "401 Unauthorized", json: nil); return
        }

        // WS /builds/{id}/logs
        if method == "GET", segs.count == 3, segs[0] == "builds", segs[2] == "logs",
           headerValue(header, "upgrade")?.lowercased() == "websocket" {
            upgradeAndStream(conn, header: header, buildID: segs[1]); return
        }

        // GET /builds/{id}/logs?after=N — plain JSON, for the CLI (no WS client).
        if method == "GET", segs.count == 3, segs[0] == "builds", segs[2] == "logs" {
            let id = segs[1]
            let after = Int(query["after"] ?? "") ?? -1
            Task {
                let lines = await self.logsSince(id, after)
                self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(lines))
            }
            return
        }

        // GET /metrics — Prometheus text exposition (Bearer-authed; point your
        // scraper at it with `authorization: credentials: <device token>`).
        if method == "GET", path == "/metrics" {
            guard let metrics else { respond(conn, "404 Not Found", json: nil); return }
            Task { self.respondText(conn, "200 OK", text: await metrics()) }
            return
        }

        // WS /screen — live H.264 screen stream (only if a source is wired up).
        // ?window={id} points the capture at one window (CompactOS); no param
        // reverts to the whole display. One capture pipeline — last viewer wins.
        if method == "GET", path == "/screen",
           headerValue(header, "upgrade")?.lowercased() == "websocket" {
            guard screen != nil else { respond(conn, "404 Not Found", json: nil); return }
            screenTarget?(query["window"].flatMap { UInt32($0) })
            upgradeAndStreamScreen(conn, header: header); return
        }

        // WS /control — remote input events, iPad → Mac
        if method == "GET", path == "/control",
           headerValue(header, "upgrade")?.lowercased() == "websocket" {
            guard control != nil else { respond(conn, "404 Not Found", json: nil); return }
            upgradeAndControl(conn, header: header); return
        }

        // GET /apps — installed Mac apps for the shortcut deck (control-only).
        if method == "GET", path == "/apps" {
            guard control != nil else { respond(conn, "404 Not Found", json: nil); return }
            let provided = apps
            Task {
                let dto = provided?() ?? CompanionAppsDTO(apps: InstalledApps.list())
                self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(dto))
            }
            return
        }

        // GET /windows — the Mac's open windows, for the CompactOS picker.
        if method == "GET", path == "/windows" {
            guard let windows else { respond(conn, "404 Not Found", json: nil); return }
            Task { self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(await windows())) }
            return
        }

        // POST /compact/open — open/focus an app (or window) and fit it to the
        // device's screen; the response names the window to stream.
        if method == "POST", segs.count == 2, segs[0] == "compact", segs[1] == "open" {
            guard let compactOpen else { respond(conn, "404 Not Found", json: nil); return }
            guard let req = try? CompanionJSON.decoder.decode(CompanionCompactOpenRequestDTO.self, from: body) else {
                respond(conn, "400 Bad Request", json: nil); return
            }
            Task {
                if let resp = await compactOpen(req) {
                    self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(resp))
                } else {
                    self.respond(conn, "409 Conflict", json: nil)
                }
            }
            return
        }

        // GET /devices — every paired device + liveness, for the fleet map.
        if method == "GET", path == "/devices" {
            guard let devices else { respond(conn, "404 Not Found", json: nil); return }
            Task {
                if let data = await devices() {
                    self.respond(conn, "200 OK", json: data)
                } else { self.respond(conn, "404 Not Found", json: nil) }
            }
            return
        }

        // POST /apns/register — a device registers its APNs token for build
        // pushes. The bearer identifies which paired device the token is for.
        if method == "POST", segs.count == 2, segs[0] == "apns", segs[1] == "register" {
            guard let apnsRegister else { respond(conn, "404 Not Found", json: nil); return }
            Task {
                let ok = await apnsRegister(token, body)
                self.respond(conn, ok ? "200 OK" : "400 Bad Request", json: nil)
            }
            return
        }

        // POST /agent/task — dictate a task; the Mac plans + drives itself.
        if method == "POST", segs.count == 2, segs[0] == "agent", segs[1] == "task" {
            guard let agentOps else { respond(conn, "404 Not Found", json: nil); return }
            guard let req = try? CompanionJSON.decoder.decode(CompanionAgentTaskRequestDTO.self, from: body) else {
                respond(conn, "400 Bad Request", json: nil); return
            }
            Task {
                if let resp = await agentOps.start(req) {
                    self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(resp))
                } else {
                    self.respond(conn, "409 Conflict", json: nil)   // control off on the Mac
                }
            }
            return
        }

        // WS /agent/{id}/events — the live step feed.
        if method == "GET", segs.count == 3, segs[0] == "agent", segs[2] == "events",
           headerValue(header, "upgrade")?.lowercased() == "websocket" {
            guard agentOps != nil else { respond(conn, "404 Not Found", json: nil); return }
            upgradeAndStreamAgent(conn, header: header, agentID: segs[1]); return
        }

        // GET /agent/{id}/events?after=N — the same feed as plain JSON.
        if method == "GET", segs.count == 3, segs[0] == "agent", segs[2] == "events" {
            guard let agentOps else { respond(conn, "404 Not Found", json: nil); return }
            let id = segs[1]
            let after = Int(query["after"] ?? "") ?? -1
            Task {
                let events = await agentOps.eventsSince(id, after)
                self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(events))
            }
            return
        }

        // POST /agent/{id}/stop — abort the run.
        if method == "POST", segs.count == 3, segs[0] == "agent", segs[2] == "stop" {
            guard let agentOps else { respond(conn, "404 Not Found", json: nil); return }
            let id = segs[1]
            Task {
                let ok = await agentOps.stop(id)
                self.respond(conn, ok ? "200 OK" : "404 Not Found", json: nil)
            }
            return
        }

        // POST /agent/{id}/decision — approve/skip an awaiting step.
        if method == "POST", segs.count == 3, segs[0] == "agent", segs[2] == "decision" {
            guard let agentOps else { respond(conn, "404 Not Found", json: nil); return }
            guard let req = try? CompanionJSON.decoder.decode(CompanionAgentDecisionDTO.self, from: body) else {
                respond(conn, "400 Bad Request", json: nil); return
            }
            let id = segs[1]
            Task {
                let ok = await agentOps.decision(id, req.seq, req.approve)
                self.respond(conn, ok ? "200 OK" : "404 Not Found", json: nil)
            }
            return
        }

        // GET /power — reachability + wake/unlock state (and the MAC for WoL).
        if method == "GET", path == "/power" {
            guard let power else { respond(conn, "404 Not Found", json: nil); return }
            Task { self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(await power())) }
            return
        }

        // POST /power/wake — light the display / declare activity.
        if method == "POST", segs.count == 2, segs[0] == "power", segs[1] == "wake" {
            guard let wake else { respond(conn, "404 Not Found", json: nil); return }
            Task { await wake(); self.respond(conn, "200 OK", json: nil) }
            return
        }

        // POST /power/unlock — type the stored password at the lock screen.
        if method == "POST", segs.count == 2, segs[0] == "power", segs[1] == "unlock" {
            guard let unlock else { respond(conn, "404 Not Found", json: nil); return }
            Task {
                let ok = await unlock()
                self.respond(conn, ok ? "200 OK" : "409 Conflict", json: nil)
            }
            return
        }

        // POST /power/privacy — set the privacy curtain. Body {"on": Bool}
        // (default true); replies {"on": Bool} with the resulting state.
        if method == "POST", segs.count == 2, segs[0] == "power", segs[1] == "privacy" {
            guard let privacy else { respond(conn, "404 Not Found", json: nil); return }
            struct Toggle: Decodable { var on: Bool? }
            let on = (try? CompanionJSON.decoder.decode(Toggle.self, from: body))?.on ?? true
            Task {
                let result = await privacy(on)
                self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(["on": result]))
            }
            return
        }

        // POST /power/lock — lock the Mac's screen.
        if method == "POST", segs.count == 2, segs[0] == "power", segs[1] == "lock" {
            guard let lock else { respond(conn, "404 Not Found", json: nil); return }
            Task {
                let ok = await lock()
                self.respond(conn, ok ? "200 OK" : "409 Conflict", json: nil)
            }
            return
        }

        // GET /ai/models — models available on the Mac's local Ollama.
        if method == "GET", path == "/ai/models" {
            guard let aiModels else { respond(conn, "404 Not Found", json: nil); return }
            Task {
                if let data = await aiModels() {
                    self.respond(conn, "200 OK", json: data)
                } else {
                    self.respond(conn, "503 Service Unavailable", json: nil)
                }
            }
            return
        }

        // POST /ai/chat — stream a chat completion. The reply is NDJSON (one
        // JSON object per line), sent with Connection: close so the client
        // reads to EOF; each line is relayed the instant Ollama produces it.
        if method == "POST", path == "/ai/chat" {
            guard let aiChat else { respond(conn, "404 Not Found", json: nil); return }
            let head = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/x-ndjson\r\n"
                + "Connection: close\r\n\r\n"
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            Task {
                await aiChat(body) { line in
                    conn.send(content: line, completion: .contentProcessed { _ in })
                }
                conn.cancel()
            }
            return
        }

        // WS /term?cwd= — a live shell (PTY) on the Mac for the Code terminal.
        if method == "GET", path == "/term",
           headerValue(header, "upgrade")?.lowercased() == "websocket" {
            guard termOps != nil else { respond(conn, "404 Not Found", json: nil); return }
            upgradeAndTerm(conn, header: header, cwd: query["cwd"]); return
        }

        // /code — native file browsing/editing for the companion's Code screen.
        if segs.first == "code" {
            guard let codeOps else { respond(conn, "404 Not Found", json: nil); return }

            // GET /code/xcode/projects — Xcode projects/workspaces on the Mac.
            if method == "GET", segs.count == 3, segs[1] == "xcode", segs[2] == "projects" {
                guard let fetch = codeOps.xcodeProjects else { respond(conn, "404 Not Found", json: nil); return }
                Task {
                    if let listing = await fetch() {
                        self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(listing))
                    } else { self.respond(conn, "404 Not Found", json: nil) }
                }
                return
            }
            // GET /code/xcode/destinations — xcodebuild destination strings.
            if method == "GET", segs.count == 3, segs[1] == "xcode", segs[2] == "destinations" {
                guard let fetch = codeOps.xcodeDestinations else { respond(conn, "404 Not Found", json: nil); return }
                Task {
                    if let list = await fetch() {
                        self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(list))
                    } else { self.respond(conn, "404 Not Found", json: nil) }
                }
                return
            }
            // GET /code/xcode/schemes?path= — a project's schemes (xcodebuild).
            if method == "GET", segs.count == 3, segs[1] == "xcode", segs[2] == "schemes" {
                guard let fetch = codeOps.xcodeSchemes else { respond(conn, "404 Not Found", json: nil); return }
                let project = query["path"] ?? ""
                Task {
                    if let schemes = await fetch(project) {
                        self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(schemes))
                    } else { self.respond(conn, "502 Bad Gateway", json: nil) }
                }
                return
            }
            // GET /code/list?path= — directory listing (folders first).
            if method == "GET", segs.count == 2, segs[1] == "list" {
                let dir = query["path"] ?? "~"
                Task {
                    if let listing = await codeOps.list(dir) {
                        self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(listing))
                    } else { self.respond(conn, "404 Not Found", json: nil) }
                }
                return
            }
            // GET /code/file?path= — read a text file (415 if not UTF-8 text).
            if method == "GET", segs.count == 2, segs[1] == "file" {
                let file = query["path"] ?? ""
                Task {
                    if let dto = await codeOps.read(file) {
                        self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(dto))
                    } else { self.respond(conn, "415 Unsupported Media Type", json: nil) }
                }
                return
            }
            // PUT /code/file — write a text file back.
            if method == "PUT", segs.count == 2, segs[1] == "file" {
                guard let dto = try? CompanionJSON.decoder.decode(CompanionCodeFileDTO.self, from: body) else {
                    respond(conn, "400 Bad Request", json: nil); return
                }
                Task {
                    let ok = await codeOps.write(dto.path, dto.content)
                    self.respond(conn, ok ? "200 OK" : "409 Conflict", json: nil)
                }
                return
            }
            // POST /code/open — open the path in the Mac's editor.
            if method == "POST", segs.count == 2, segs[1] == "open" {
                guard let dto = try? CompanionJSON.decoder.decode(CompanionCodeOpenDTO.self, from: body) else {
                    respond(conn, "400 Bad Request", json: nil); return
                }
                Task {
                    let ok = await codeOps.open(dto.path)
                    self.respond(conn, ok ? "200 OK" : "409 Conflict", json: nil)
                }
                return
            }
        }

        // /flows — visual automations: the companion edits them, this Mac runs
        // them. Bodies are opaque to the server (the app owns the shapes).
        if segs.first == "flows" {
            guard let ops = flowOps else { respond(conn, "404 Not Found", json: nil); return }

            // GET /flows — every saved flow.
            if method == "GET", segs.count == 1 {
                Task {
                    if let data = await ops.list() {
                        self.respond(conn, "200 OK", json: data)
                    } else { self.respond(conn, "403 Forbidden", json: nil) }
                }
                return
            }
            // PUT /flows — upsert one flow (whole graph).
            if method == "PUT", segs.count == 1 {
                Task { self.respond(conn, await ops.save(body) ? "200 OK" : "403 Forbidden", json: nil) }
                return
            }
            // GET /flows/runs/{runId} — one run (live while executing).
            if method == "GET", segs.count == 3, segs[1] == "runs" {
                Task {
                    if let data = await ops.runDetail(segs[2]) {
                        self.respond(conn, "200 OK", json: data)
                    } else { self.respond(conn, "404 Not Found", json: nil) }
                }
                return
            }
            // POST /flows/runs/{runId}/cancel
            if method == "POST", segs.count == 4, segs[1] == "runs", segs[3] == "cancel" {
                Task { self.respond(conn, await ops.cancel(segs[2]) ? "200 OK" : "404 Not Found", json: nil) }
                return
            }
            // GET /flows/{id}/runs — the flow's run history.
            if method == "GET", segs.count == 3, segs[2] == "runs" {
                Task {
                    if let data = await ops.runs(segs[1]) {
                        self.respond(conn, "200 OK", json: data)
                    } else { self.respond(conn, "403 Forbidden", json: nil) }
                }
                return
            }
            // POST /flows/{id}/run — start a run; body carries payload/key.
            if method == "POST", segs.count == 3, segs[2] == "run" {
                Task {
                    if let data = await ops.run(segs[1], body) {
                        self.respond(conn, "200 OK", json: data)
                    } else { self.respond(conn, "403 Forbidden", json: nil) }
                }
                return
            }
            // DELETE /flows/{id}
            if method == "DELETE", segs.count == 2 {
                Task { self.respond(conn, await ops.remove(segs[1]) ? "200 OK" : "404 Not Found", json: nil) }
                return
            }
        }

        // GET /builds
        if method == "GET", path == "/builds" {
            Task { self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(await self.builds())) }
            return
        }

        // GET /builds/{id}
        if method == "GET", segs.count == 2, segs[0] == "builds" {
            Task {
                guard let b = await self.build(segs[1]) else { self.respond(conn, "404 Not Found", json: nil); return }
                self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(b))
            }
            return
        }

        // POST /builds/{id}/rerun | /builds/{id}/cancel
        if method == "POST", segs.count == 3, segs[0] == "builds",
           segs[2] == "rerun" || segs[2] == "cancel" {
            guard let buildAction else { respond(conn, "404 Not Found", json: nil); return }
            let id = segs[1], act = segs[2]
            Task {
                let ok = await buildAction(id, act)
                self.respond(conn, ok ? "200 OK" : "409 Conflict", json: nil)
            }
            return
        }

        // /pipelines — remote pipeline management (mirrors the Mac app's UI).
        if segs.first == "pipelines" {
            guard let ops = pipelineOps else { respond(conn, "404 Not Found", json: nil); return }

            // GET /pipelines
            if method == "GET", segs.count == 1 {
                Task { self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(await ops.list())) }
                return
            }
            // GET /pipelines/repos?provider=&workspace= — for the editor's picker
            if method == "GET", segs.count == 2, segs[1] == "repos" {
                let provider = query["provider"] ?? "bitbucket"
                let ws = query["workspace"] ?? ""
                Task {
                    if let names = await ops.repos(provider, ws) {
                        self.respond(conn, "200 OK",
                                     json: try? CompanionJSON.encoder.encode(CompanionListDTO(values: names)))
                    } else { self.respond(conn, "502 Bad Gateway", json: nil) }
                }
                return
            }
            // GET /pipelines/branches?provider=&workspace=&repo=
            if method == "GET", segs.count == 2, segs[1] == "branches" {
                let provider = query["provider"] ?? "bitbucket"
                let ws = query["workspace"] ?? ""
                let repo = query["repo"] ?? ""
                Task {
                    if let names = await ops.branches(provider, ws, repo) {
                        self.respond(conn, "200 OK",
                                     json: try? CompanionJSON.encoder.encode(CompanionListDTO(values: names)))
                    } else { self.respond(conn, "502 Bad Gateway", json: nil) }
                }
                return
            }
            // POST /pipelines — create
            if method == "POST", segs.count == 1 {
                Task { self.respond(conn, await ops.create(body) ? "200 OK" : "422 Unprocessable Entity", json: nil) }
                return
            }
            // PUT /pipelines/{id} — update config
            if method == "PUT", segs.count == 2 {
                let id = segs[1]
                Task { self.respond(conn, await ops.update(id, body) ? "200 OK" : "404 Not Found", json: nil) }
                return
            }
            // DELETE /pipelines/{id}
            if method == "DELETE", segs.count == 2 {
                let id = segs[1]
                Task { self.respond(conn, await ops.remove(id) ? "200 OK" : "404 Not Found", json: nil) }
                return
            }
            // POST /pipelines/{id}/watch | unwatch | run
            if method == "POST", segs.count == 3 {
                let id = segs[1]
                switch segs[2] {
                case "watch":
                    Task { self.respond(conn, await ops.watch(id, true) ? "200 OK" : "404 Not Found", json: nil) }
                case "unwatch":
                    Task { self.respond(conn, await ops.watch(id, false) ? "200 OK" : "404 Not Found", json: nil) }
                case "run":
                    Task { self.respond(conn, await ops.run(id) ? "200 OK" : "404 Not Found", json: nil) }
                default:
                    respond(conn, "404 Not Found", json: nil)
                }
                return
            }
        }

        respond(conn, "404 Not Found", json: nil)
    }

    // MARK: Plain HTTP response (closes the connection)

    /// text/plain response — Prometheus and friends.
    private func respondText(_ conn: NWConnection, _ status: String, text: String) {
        let payload = Data(text.utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func respond(_ conn: NWConnection, _ status: String, json: Data?) {
        let payload = json ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(payload)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: WebSocket

    /// One live socket. `open` gates the push loop; the reader flips it when the
    /// client disconnects. `sending` prevents frames piling up faster than the
    /// link drains. `onClose` runs once when the socket closes.
    private final class WSState: @unchecked Sendable {
        var open = true
        var lastSeq = -1
        var sending = false
        var awaitingKey = false          // dropped a frame → wait for an IDR to resync
        var onClose: (@Sendable () -> Void)?

        // Screen path: bytes handed to the connection but not yet accepted by
        // the transport. Guarded by its own lock so the frame path never has
        // to hop through the server's shared queue.
        let sendLock = NSLock()
        var inflightBytes = 0
    }

    private func upgradeAndStream(_ conn: NWConnection, header: String, buildID: String) {
        guard let key = headerValue(header, "sec-websocket-key") else { respond(conn, "400 Bad Request", json: nil); return }
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data((key + magic).utf8))).base64EncodedString()
        let handshake = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"

        let state = WSState()
        conn.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.drainClient(conn, state: state)   // detect close
            self.pushLoop(conn, buildID: buildID, state: state)
        })
    }

    /// Poll for new log lines and push them as text frames until the client goes.
    private func pushLoop(_ conn: NWConnection, buildID: String, state: WSState) {
        guard state.open else { conn.cancel(); return }
        Task {
            let lines = await self.logsSince(buildID, state.lastSeq)
            for line in lines {
                guard let data = try? CompanionJSON.encoder.encode(line) else { continue }
                self.send(conn, payload: data)
                state.lastSeq = max(state.lastSeq, line.seq)
            }
            self.queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.pushLoop(conn, buildID: buildID, state: state)
            }
        }
    }

    /// WS /agent/{id}/events — the step feed, same poll-and-push shape as the
    /// build-log stream: JSON text frames, one event per frame.
    private func upgradeAndStreamAgent(_ conn: NWConnection, header: String, agentID: String) {
        guard let key = headerValue(header, "sec-websocket-key") else { respond(conn, "400 Bad Request", json: nil); return }
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data((key + magic).utf8))).base64EncodedString()
        let handshake = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"

        let state = WSState()
        conn.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.drainClient(conn, state: state)
            self.pushAgentLoop(conn, agentID: agentID, state: state)
        })
    }

    private func pushAgentLoop(_ conn: NWConnection, agentID: String, state: WSState) {
        guard state.open, let agentOps else { conn.cancel(); return }
        Task {
            let events = await agentOps.eventsSince(agentID, state.lastSeq)
            for event in events {
                guard let data = try? CompanionJSON.encoder.encode(event) else { continue }
                self.send(conn, payload: data)
                state.lastSeq = max(state.lastSeq, event.seq)
            }
            self.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.pushAgentLoop(conn, agentID: agentID, state: state)
            }
        }
    }

    /// We don't parse inbound frames — just notice when the socket closes.
    private func drainClient(_ conn: NWConnection, state: WSState) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                state.open = false
                state.onClose?(); state.onClose = nil
                conn.cancel(); return
            }
            self?.drainClient(conn, state: state)
        }
    }

    // MARK: Screen streaming

    /// Upgrade to WebSocket and push encoded H.264 packets from the broadcaster.
    /// Each viewer is a sink; if it falls behind, frames are dropped and an IDR
    /// is requested so the decoder recovers at the next keyframe.
    private func upgradeAndStreamScreen(_ conn: NWConnection, header: String) {
        guard let broadcaster = screen else { respond(conn, "404 Not Found", json: nil); return }
        guard let key = headerValue(header, "sec-websocket-key") else { respond(conn, "400 Bad Request", json: nil); return }
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data((key + magic).utf8))).base64EncodedString()
        let handshake = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"

        let id = ObjectIdentifier(conn)
        let state = WSState()
        state.onClose = { broadcaster.removeViewer(id) }

        conn.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.drainClient(conn, state: state)
            // Frames go straight from the encoder thread to conn.send (thread-
            // safe) — never through the server's shared queue, which also
            // carries control traffic and would stall the 60fps cadence.
            // Backpressure is a bytes-in-flight budget: TCP keeps ordering, so
            // several frames may be in flight; only when the transport stops
            // draining do we drop. After a drop we must NOT send a P-frame
            // whose reference was skipped (that's the "glitch") — drop until
            // the next IDR, which we request immediately.
            // Sized to absorb a full-screen-motion burst (Mission Control, app
            // switch): a transient ~1.5 MB backlog ≈ 270 ms at 45 Mbps — better
            // a brief latency bump than a drop→IDR stutter.
            let budget = 1536 * 1024
            broadcaster.addViewer(id) { [weak conn] packet in
                guard let conn, state.open else { return }
                state.sendLock.lock()
                if state.inflightBytes > budget {
                    let firstDrop = !state.awaitingKey
                    state.awaitingKey = true
                    state.sendLock.unlock()
                    broadcaster.noteDropped()
                    if firstDrop { broadcaster.onNeedKeyframe?() }
                    return
                }
                if state.awaitingKey {
                    guard (packet.first ?? 0) & 1 == 1 else {   // skip corrupt P-frames
                        state.sendLock.unlock()
                        broadcaster.noteDropped()
                        return
                    }
                    state.awaitingKey = false
                }
                state.inflightBytes += packet.count
                state.sendLock.unlock()
                broadcaster.noteSent()

                var frame = Data([0x82])
                let n = packet.count
                if n < 126 {
                    frame.append(UInt8(n))
                } else if n <= 0xFFFF {
                    frame.append(126); frame.append(UInt8(n >> 8)); frame.append(UInt8(n & 0xFF))
                } else {
                    frame.append(127)
                    for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((n >> shift) & 0xFF)) }
                }
                frame.append(packet)
                conn.send(content: frame, completion: .contentProcessed { _ in
                    state.sendLock.lock(); state.inflightBytes -= packet.count; state.sendLock.unlock()
                })
            }
        })
    }

    // MARK: Terminal (bidirectional)

    /// Upgrade to WebSocket and bridge a PTY session: raw shell output goes
    /// out as binary frames; JSON text frames carry keystrokes and resizes in.
    private func upgradeAndTerm(_ conn: NWConnection, header: String, cwd: String?) {
        guard let ops = termOps else { respond(conn, "404 Not Found", json: nil); return }
        guard let key = headerValue(header, "sec-websocket-key") else { respond(conn, "400 Bad Request", json: nil); return }
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data((key + magic).utf8))).base64EncodedString()
        let handshake = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"

        let sessionID = UUID().uuidString
        let state = WSState()
        state.onClose = { Task { await ops.close(sessionID) } }

        conn.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            Task {
                // Output path: PTY bytes → binary frames, straight to the socket.
                let started = await ops.start(sessionID, cwd) { [weak conn] bytes in
                    guard let conn, state.open else { return }
                    self.send(conn, payload: bytes, opcode: 0x82)
                }
                guard started else {
                    state.open = false
                    conn.cancel()
                    return
                }
                // Input path: parse client frames on the server queue.
                self.queue.async { self.readTerm(conn, buffer: Data(), state: state, ops: ops, id: sessionID) }
            }
        })
    }

    private func readTerm(_ conn: NWConnection, buffer: Data, state: WSState,
                          ops: TermOps, id: String) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var acc = buffer
            if let data, !data.isEmpty { acc.append(data) }
            let leftover = self.parseFrames(acc, conn: conn) { payload in
                guard let inbound = try? Self.controlDecoder.decode(TermInbound.self, from: payload) else { return }
                switch inbound.t {
                case "in":
                    if let d = inbound.d, let bytes = Data(base64Encoded: d) {
                        Task { await ops.input(id, bytes) }
                    }
                case "size":
                    if let c = inbound.c, let r = inbound.r {
                        Task { await ops.resize(id, c, r) }
                    }
                default: break
                }
            }
            if isComplete || error != nil {
                state.open = false
                state.onClose?(); state.onClose = nil
                conn.cancel(); return
            }
            self.readTerm(conn, buffer: leftover, state: state, ops: ops, id: id)
        }
    }

    /// Parse complete masked client frames, handing each text/binary payload
    /// to `onPayload`; returns trailing partial-frame bytes.
    private func parseFrames(_ buffer: Data, conn: NWConnection,
                             onPayload: (Data) -> Void) -> Data {
        let buf = [UInt8](buffer)
        var off = 0
        while buf.count - off >= 2 {
            let opcode = buf[off] & 0x0F
            let masked = (buf[off + 1] & 0x80) != 0
            var len = Int(buf[off + 1] & 0x7F)
            var hdr = 2
            if len == 126 {
                guard buf.count - off >= 4 else { break }
                len = Int(buf[off + 2]) << 8 | Int(buf[off + 3]); hdr = 4
            } else if len == 127 {
                guard buf.count - off >= 10 else { break }
                len = 0; for k in 0..<8 { len = (len << 8) | Int(buf[off + 2 + k]) }; hdr = 10
            }
            let maskLen = masked ? 4 : 0
            let total = hdr + maskLen + len
            guard buf.count - off >= total else { break }

            var payload = Array(buf[(off + hdr + maskLen)..<(off + total)])
            if masked {
                let key = Array(buf[(off + hdr)..<(off + hdr + 4)])
                for i in 0..<payload.count { payload[i] ^= key[i % 4] }
            }
            off += total

            switch opcode {
            case 0x8: conn.cancel(); return Data()          // close
            case 0x1, 0x2: onPayload(Data(payload))         // text / binary
            default: break                                  // ping/pong — ignore
            }
        }
        return off < buf.count ? Data(buf[off...]) : Data()
    }

    // MARK: Remote control (inbound)

    /// Upgrade to WebSocket, then read masked client frames and decode input events.
    private func upgradeAndControl(_ conn: NWConnection, header: String) {
        guard let key = headerValue(header, "sec-websocket-key") else { respond(conn, "400 Bad Request", json: nil); return }
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data((key + magic).utf8))).base64EncodedString()
        let handshake = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] _ in
            self?.readControl(conn, buffer: Data())
        })
    }

    private func readControl(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var acc = buffer
            if let data, !data.isEmpty { acc.append(data) }
            let leftover = self.parseControlFrames(acc, conn: conn)
            if isComplete || error != nil { conn.cancel(); return }
            self.readControl(conn, buffer: leftover)
        }
    }

    /// Parse complete client frames (masked), dispatch text/binary payloads as
    /// ControlEvents, and return any trailing partial-frame bytes.
    private func parseControlFrames(_ buffer: Data, conn: NWConnection) -> Data {
        let buf = [UInt8](buffer)
        var off = 0
        while buf.count - off >= 2 {
            let opcode = buf[off] & 0x0F
            let masked = (buf[off + 1] & 0x80) != 0
            var len = Int(buf[off + 1] & 0x7F)
            var hdr = 2
            if len == 126 {
                guard buf.count - off >= 4 else { break }
                len = Int(buf[off + 2]) << 8 | Int(buf[off + 3]); hdr = 4
            } else if len == 127 {
                guard buf.count - off >= 10 else { break }
                len = 0; for k in 0..<8 { len = (len << 8) | Int(buf[off + 2 + k]) }; hdr = 10
            }
            let maskLen = masked ? 4 : 0
            let total = hdr + maskLen + len
            guard buf.count - off >= total else { break }

            var payload = Array(buf[(off + hdr + maskLen)..<(off + total)])
            if masked {
                let key = Array(buf[(off + hdr)..<(off + hdr + 4)])
                for i in 0..<payload.count { payload[i] ^= key[i % 4] }
            }
            off += total

            switch opcode {
            case 0x8: conn.cancel(); return Data()                       // close
            case 0x1, 0x2:                                                // text / binary
                if let event = try? Self.controlDecoder.decode(ControlEvent.self, from: Data(payload)) {
                    control?(event)
                }
            default: break                                               // ping/pong — ignore
            }
        }
        return off < buf.count ? Data(buf[off...]) : Data()
    }

    /// Encode one unmasked server→client frame (RFC 6455 §5). `opcode` 0x81 = text, 0x82 = binary.
    private func send(_ conn: NWConnection, payload: Data, opcode: UInt8 = 0x81,
                      completion: (@Sendable () -> Void)? = nil) {
        var frame = Data([opcode])
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(n))
        } else if n <= 0xFFFF {
            frame.append(126); frame.append(UInt8(n >> 8)); frame.append(UInt8(n & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((n >> shift) & 0xFF)) }
        }
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { _ in completion?() })
    }

    // MARK: Header helpers

    private func bearer(_ header: String) -> String? {
        guard let v = headerValue(header, "authorization"), v.lowercased().hasPrefix("bearer ") else { return nil }
        return String(v.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }

    private func headerValue(_ header: String, _ name: String) -> String? {
        for line in header.split(separator: "\r\n").dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func headerInt(_ header: String, _ name: String) -> Int? {
        headerValue(header, name).flatMap { Int($0) }
    }
}
