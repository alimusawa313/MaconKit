//
//  CompanionServer.swift
//  MaconKit
//
//  HTTP + WebSocket server for the companion app. Zero dependencies
//  (Network.framework), same style as WebhookServer. Routes:
//
//    POST /pair                 (no auth)  device-code → token
//    POST /unpair               (Bearer)   end this device's pairing (revokes its token)
//    GET  /lan                  (Bearer)   LAN port + the certificate to pin there
//    GET  /builds               (Bearer)   build list
//    GET  /builds/{id}          (Bearer)   one build
//    POST /builds/{id}/rerun    (Bearer)   trigger a fresh run of its pipeline
//    POST /builds/{id}/cancel   (Bearer)   stop it if it's building
//    POST /builds/{id}/install  (Bearer)   put the app it built on a device {device}
//    GET  /hardware             (Bearer)   iPhones/iPads paired with this Mac's Xcode
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
//    POST /screen/claim         (Bearer)   move the screen session to this device
//    POST /agent/task           (Bearer)   dictate a task; the Mac drives itself
//    WS   /agent/{id}/events    (Bearer)   agent step feed (JSON text frames)
//    POST /agent/{id}/stop      (Bearer)   abort an agent run
//    POST /agent/{id}/decision  (Bearer)   approve/skip an awaiting agent step
//    WS   /screen?window={id}   (Bearer)   stream one window instead of the display
//    WS   /audio                (Bearer)   encoded Mac system audio → device
//    WS   /mic                  (Bearer)   encoded device microphone → Mac
//    GET  /audio/status         (Bearer)   driver + consent state for media I/O
//    GET  /clipboard?after=N    (Bearer)   the Mac's latest clipboard item (universal copy & paste)
//    POST /clipboard            (Bearer)   set the Mac's clipboard from a device
//    POST /coding-agents/hook   (Bearer)   a coding agent (Claude Code, Codex) reports a moment
//    GET  /coding-agents        (Bearer)   the agent sessions on this Mac and their prompts
//    GET  /coding-agents/{id}   (Bearer)   one session with its timeline
//    GET  /coding-agents/{id}/decision?seq=N&wait=S  (Bearer)  the hook long-polls for an answer
//    POST /coding-agents/{id}/decision  (Bearer)  a device answers a prompt {seq, allow}
//    DELETE /coding-agents/{id} (Bearer)   forget a session
//    GET  /recap?since=T        (Bearer)   what happened on this Mac since T (Unix seconds)
//    GET  /maco                 (Bearer)   Maco's mood right now: {"maco": {...}} or {} when idle
//    POST /maco/test            (Bearer)   walk Maco's card through every mood, for testing
//
//  Two listeners, because the two ways in have different protection:
//
//    • the configured port, on every interface, over TLS with the Mac's own
//      self-signed certificate (LANIdentity), which paired devices pin. This is
//      the direct LAN path, and it used to be cleartext — meaning the
//      `Authorization: Bearer` header was readable by anyone on the same Wi-Fi,
//      and replayable for ever after.
//    • port + 1, bound to 127.0.0.1 only, cleartext, for cloudflared. Cloudflare
//      terminates TLS in front of it and nothing on the network can reach it.
//
//  So a headless EC2 Mac is reachable at a stable https/wss URL through the
//  tunnel, and a device at home talks to the Mac directly without putting its
//  token on the wire.
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
    /// The Mac's home folder for a paired device's Files app. Every closure
    /// answers nil/false when the files toggle is off there, which the routes
    /// turn into 403 rather than an empty listing.
    public struct FileOps: Sendable {
        public var list: @Sendable (String) async -> CompanionFileListDTO?
        public var item: @Sendable (String) async -> CompanionFileEntryDTO?
        public var read: @Sendable (String) async -> Data?
        public var write: @Sendable (String, Data) async -> CompanionFileEntryDTO?
        public var makeDirectory: @Sendable (String) async -> CompanionFileEntryDTO?
        public var delete: @Sendable (String) async -> Bool
        public var move: @Sendable (String, String) async -> CompanionFileEntryDTO?

        public init(list: @escaping @Sendable (String) async -> CompanionFileListDTO?,
                    item: @escaping @Sendable (String) async -> CompanionFileEntryDTO?,
                    read: @escaping @Sendable (String) async -> Data?,
                    write: @escaping @Sendable (String, Data) async -> CompanionFileEntryDTO?,
                    makeDirectory: @escaping @Sendable (String) async -> CompanionFileEntryDTO?,
                    delete: @escaping @Sendable (String) async -> Bool,
                    move: @escaping @Sendable (String, String) async -> CompanionFileEntryDTO?) {
            self.list = list; self.item = item; self.read = read; self.write = write
            self.makeDirectory = makeDirectory; self.delete = delete; self.move = move
        }
    }

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
    /// /term route 404s). Raw output bytes stream out as binary frames,
    /// input/resizes arrive as JSON text frames. A session the client marked
    /// persistent survives its socket and can be reattached by id.
    public struct TermOps: Sendable {
        /// Start a session: id, working directory, and the sink for output
        /// bytes. False = refused (feature off).
        /// Start a session: id, working directory, persist flag, and the sink
        /// for output bytes. An id the Mac already knows reattaches instead.
        public var start: @Sendable (String, String?, Bool, @escaping @Sendable (Data) -> Void) async -> Bool
        public var input: @Sendable (String, Data) async -> Void
        public var resize: @Sendable (String, Int, Int) async -> Void
        /// The socket closed. A persistent session is kept for reattach;
        /// anything else should die here.
        public var detach: @Sendable (String) async -> Void
        public var close: @Sendable (String) async -> Void

        public init(start: @escaping @Sendable (String, String?, Bool, @escaping @Sendable (Data) -> Void) async -> Bool,
                    input: @escaping @Sendable (String, Data) async -> Void,
                    resize: @escaping @Sendable (String, Int, Int) async -> Void,
                    detach: @escaping @Sendable (String) async -> Void,
                    close: @escaping @Sendable (String) async -> Void) {
            self.start = start; self.input = input; self.resize = resize
            self.detach = detach; self.close = close
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
        /// A live partial transcript: open the app it names, if any, right now.
        /// Nil = refused (control off) → 409.
        public var eager: @Sendable (CompanionAgentEagerRequestDTO) async -> CompanionAgentEagerResponseDTO?

        public init(start: @escaping @Sendable (CompanionAgentTaskRequestDTO) async -> CompanionAgentStartResponseDTO?,
                    eventsSince: @escaping @Sendable (String, Int) async -> [CompanionAgentEventDTO],
                    stop: @escaping @Sendable (String) async -> Bool,
                    decision: @escaping @Sendable (String, Int, Bool) async -> Bool,
                    eager: @escaping @Sendable (CompanionAgentEagerRequestDTO) async -> CompanionAgentEagerResponseDTO? = { _ in nil }) {
            self.start = start; self.eventsSince = eventsSince
            self.stop = stop; self.decision = decision; self.eager = eager
        }
    }

    /// The remote-microphone uplink (nil = the /mic route 404s). One live
    /// source at a time — a new connection evicts the previous one, matching
    /// the screen's last-device-wins semantics.
    public struct MicOps: Sendable {
        /// A companion mic went live / the last one left. What flips the Mac's
        /// default input onto the virtual microphone and back.
        public var onActive: @Sendable (Bool) -> Void
        /// One encoded audio packet from the device (AudioPacket wire format).
        public var packet: @Sendable (Data) -> Void

        public init(onActive: @escaping @Sendable (Bool) -> Void,
                    packet: @escaping @Sendable (Data) -> Void) {
            self.onActive = onActive; self.packet = packet
        }
    }

    /// Universal clipboard (nil = the /clipboard routes 404). Payloads are
    /// encoded CompanionClipboardDTOs; the app owns the pasteboard bridging.
    public struct ClipboardOps: Sendable {
        /// The newest item, when newer than `after` (empty reps otherwise, so
        /// the poll stays cheap). Nil = refused (403, the toggle is off).
        public var latest: @Sendable (Int) async -> Data?
        /// A device's clipboard becomes the Mac's; returns the ack ({seq}) so
        /// the sender skips its own echo. Nil = refused (403) or a bad body.
        public var push: @Sendable (Data) async -> Data?

        public init(latest: @escaping @Sendable (Int) async -> Data?,
                    push: @escaping @Sendable (Data) async -> Data?) {
            self.latest = latest; self.push = push
        }
    }

    /// Coding agents on this Mac (nil = the /coding-agents routes 404). The
    /// hook route is open to any paired token, the CLI's included; whether a
    /// device may SEE sessions and ANSWER prompts is the app's toggle, which
    /// `list`/`decide` report as nil/false → 403.
    public struct CodingAgentOps: Sendable {
        public var hook: @Sendable (CodingAgentHookEvent) async -> CodingAgentHookResponse
        public var waitDecision: @Sendable (String, Int, TimeInterval) async -> CodingAgentHookResponse
        public var list: @Sendable () async -> CompanionCodingAgentsDTO?
        /// One session with its timeline. Nil = off or unknown; the route
        /// answers 403 when `list` would, else 404.
        public var detail: @Sendable (String) async -> CompanionCodingAgentDTO?
        /// nil = feature off (403); false = no such prompt (404).
        public var decide: @Sendable (String, CompanionCodingAgentDecisionDTO) async -> Bool?
        public var remove: @Sendable (String) async -> Bool

        public init(hook: @escaping @Sendable (CodingAgentHookEvent) async -> CodingAgentHookResponse,
                    waitDecision: @escaping @Sendable (String, Int, TimeInterval) async -> CodingAgentHookResponse,
                    list: @escaping @Sendable () async -> CompanionCodingAgentsDTO?,
                    detail: @escaping @Sendable (String) async -> CompanionCodingAgentDTO? = { _ in nil },
                    decide: @escaping @Sendable (String, CompanionCodingAgentDecisionDTO) async -> Bool?,
                    remove: @escaping @Sendable (String) async -> Bool) {
            self.hook = hook; self.waitDecision = waitDecision; self.list = list
            self.detail = detail; self.decide = decide; self.remove = remove
        }
    }

    /// One inbound terminal frame: keystrokes (base64) or a resize.
    private struct TermInbound: Decodable {
        let t: String            // "in" | "size" | "kill"
        let d: String?           // base64 input bytes
        let c: Int?              // cols
        let r: Int?              // rows
    }

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "macon.companion")

    /// The cleartext port, loopback only, that cloudflared connects to. Derived
    /// from the configured port rather than configured separately, so there is
    /// still one number for anyone to think about.
    public static func loopbackPort(for port: UInt16) -> UInt16 {
        port == UInt16.max ? port - 1 : port + 1
    }
    public var loopbackPort: UInt16 { Self.loopbackPort(for: port.rawValue) }

    /// The LAN listener's TLS identity, resolved on the first bind. Nil means no
    /// LAN listener at all: the tunnel keeps working and the LAN is simply not
    /// served, which is the right way to fail. Serving it in the clear instead
    /// would hand the bearer token to anyone on the same Wi-Fi.
    private var lanTLS: LANIdentity.Loaded?
    private var lanTLSResolved = false

    /// `lanTLS?.pin`, reachable from off `queue` (the /pair route answers inside
    /// a Task, and the app wants it for the beacon).
    private let pinLock = NSLock()
    private var publishedPin: String?
    public var lanCertPin: String? {
        pinLock.lock(); defer { pinLock.unlock() }
        return publishedPin
    }

    private let authorize: Authorize
    private let pair: Pair
    /// The calling device ends its own pairing: revoke its token. Returns
    /// whether anything was actually revoked. Nil = the route 404s (older
    /// wiring), which devices treat as best-effort.
    private let unpair: (@Sendable (String) async -> Bool)?
    private let builds: Builds
    private let build: Build
    private let logsSince: LogsSince
    private let buildAction: BuildActionFn?
    /// Install a finished build's app on a device (nil = 404). A nil result
    /// means no such build or nothing to install.
    private let installBuild: (@Sendable (_ id: String, _ device: String) async -> CompanionInstallResultDTO?)?
    /// The devices Xcode has paired (nil = 404).
    private let hardware: (@Sendable () async -> CompanionHardwareDTO)?
    private let pipelineOps: PipelineOps?
    /// Prometheus text for GET /metrics (nil disables the route).
    private let metrics: (@Sendable () async -> String)?
    private let onLog: @Sendable (String) -> Void
    /// Fires with whether the socket is actually bound. A busy port is not
    /// fatal here — we retry forever — but the app needs to be able to say so
    /// rather than claim it's serving when nothing is listening.
    private let onListening: @Sendable (Bool) -> Void

    /// Optional H.264 screen streaming. Nil disables the /screen route (e.g. the
    /// headless CLI, which has no display to capture).
    private let screen: ScreenBroadcaster?

    /// Live screen viewers, so we can report how many devices are watching and
    /// "move" the session — evict the others so one device has it alone.
    private final class ScreenViewer {
        weak var conn: NWConnection?
        let token: String
        let state: WSState
        init(conn: NWConnection, token: String, state: WSState) {
            self.conn = conn; self.token = token; self.state = state
        }
    }
    private let screenLock = NSLock()
    private var screenViewers: [ObjectIdentifier: ScreenViewer] = [:]
    /// Optional remote-control sink. Nil disables the /control route.
    private let control: (@Sendable (ControlEvent) -> Void)?
    /// Optional installed-app catalog (the app supplies one with icons). Falls
    /// back to a Foundation-only, icon-less enumeration.
    private let apps: (@Sendable () -> CompanionAppsDTO)?
    /// One app's icon as PNG at the requested pixel size. Icons left /apps in
    /// 1.9.3: 129 apps at 256 px was 7.8 MB of base64 in one blocking reply,
    /// which a phone gives 15 s and then reports as the Mac being unreachable.
    private let appIcon: (@Sendable (_ path: String, _ px: Int) -> Data?)?
    /// CompactOS: enumerate the Mac's open windows (nil disables /windows).
    private let windows: (@Sendable () async -> CompanionWindowsDTO)?
    /// CompactOS: open/focus an app and fit its window to the device. Returns
    /// nil when refused (e.g. remote control disabled) → 409.
    private let compactOpen: (@Sendable (CompanionCompactOpenRequestDTO) async -> CompanionCompactOpenResponseDTO?)?
    /// CompactOS: point the screen stream at one window (nil = whole display).
    /// Called on every /screen connect — last viewer wins.
    private let screenTarget: (@Sendable (UInt32?) -> Void)?
    /// The viewer's screen size in pixels (`?fit=WxH`), so the Mac can shape
    /// its virtual display to the device and the stream fills it edge to
    /// edge. (0, 0) = viewer sent no size. Last viewer wins, like the target.
    private let screenFit: (@Sendable (UInt32, UInt32) -> Void)?
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
    /// The awake timer + heat guard: nil change reads, a change applies and
    /// reads back.
    private let awake: (@Sendable (_ change: CompanionAwakeChangeDTO?) async -> CompanionAwakeDTO)?
    /// AI (local Ollama proxy). `aiModels` returns the encoded model list, or
    /// nil when the local model host is unreachable/disabled → 503. `aiChat`
    /// streams the reply: it forwards the request body to the local host and
    /// calls `emit` once per NDJSON line, which we relay to the client.
    private let aiModels: (@Sendable () async -> Data?)?
    /// Custom (user-added) OpenAI-compatible providers this Mac offers — id,
    /// name, and models (no keys), so a device can list them in its pickers.
    private let aiProviders: (@Sendable () async -> Data?)?
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
    /// The free tier's daily remote allowance. Owned here rather than injected:
    /// it has no app-side dependency, and a headless runner keeps one too.
    private let remoteMeter = RemoteMeterLedger()
    /// Open a web address in the Mac's default browser (the share sheet and
    /// Shortcuts). Answers false when remote control is off.
    private let openURL: (@Sendable (_ url: String) async -> Bool)?
    /// The Files-app view of the Mac's home folder (nil disables /files).
    private let fileOps: FileOps?
    /// The dictate-to-drive Mac agent (nil disables the /agent routes).
    private let agentOps: AgentOps?
    /// Live voice mode: one conversation turn → { say, task? }. Nil = 404.
    private let voiceTurn: (@Sendable (CompanionVoiceTurnRequestDTO) async -> CompanionVoiceTurnResponseDTO?)?
    /// Text → WAV speech (Piper on the Mac). Nil op = 404; nil Data = 503 and
    /// the device falls back to its own voice.
    private let voiceTTS: (@Sendable (String) async -> Data?)?
    /// Encoded Mac-audio downlink (nil disables the /audio route).
    private let audio: AudioBroadcaster?
    /// Remote-microphone uplink (nil disables the /mic route).
    private let micOps: MicOps?
    /// Encoded CompanionAudioStatusDTO for GET /audio/status (nil = 404).
    private let audioStatus: (@Sendable () async -> Data?)?
    /// The Mac's vitals for GET /system (nil = 404, and the device's vitals
    /// tiles say the Mac needs updating).
    private let system: (@Sendable () async -> CompanionSystemDTO)?
    /// Output devices for GET /audio/outputs, and the switch for POST
    /// /audio/output — the deck's output-picker tile.
    private let audioOutputs: (@Sendable () async -> CompanionAudioOutputsDTO)?
    private let setAudioOutput: (@Sendable (String) async -> Bool)?
    /// Universal clipboard (nil disables the /clipboard routes).
    private let clipboardOps: ClipboardOps?
    /// Coding agents (nil disables the /coding-agents routes).
    private let codingAgentOps: CodingAgentOps?
    /// "While you were gone" for the calling device (nil disables /recap).
    /// Gets the caller's token so its own doings stay out of the answer.
    private let recap: (@Sendable (_ token: String, _ since: Date) async -> Data?)?
    /// Start Maco's test tour; answers the JSON reply, or nil when there is
    /// nobody to show it to (409). Nil closure disables the route.
    private let macoTest: (@Sendable () async -> Data?)?
    /// Maco's mood right now, for the phone's 3D room (nil disables GET /maco).
    private let macoNow: (@Sendable () async -> Data?)?
    /// Every request that changes something on this Mac, or opens a live
    /// session into it, is reported here with the caller's token and how it
    /// came in ("lan" | "tunnel"). Nil = no audit.
    private let onAudit: (@Sendable (_ token: String, _ action: String, _ detail: String?, _ via: String) -> Void)?
    /// The live /mic connection, so a new source can evict it (last wins).
    private let micLock = NSLock()
    private var micConn: NWConnection?
    private var micState: WSState?

    private static let controlDecoder = JSONDecoder()

    public init(port: UInt16,
                authorize: @escaping Authorize,
                pair: @escaping Pair,
                unpair: (@Sendable (String) async -> Bool)? = nil,
                builds: @escaping Builds,
                build: @escaping Build,
                logsSince: @escaping LogsSince,
                buildAction: BuildActionFn? = nil,
                installBuild: (@Sendable (_ id: String, _ device: String) async -> CompanionInstallResultDTO?)? = nil,
                hardware: (@Sendable () async -> CompanionHardwareDTO)? = nil,
                pipelineOps: PipelineOps? = nil,
                metrics: (@Sendable () async -> String)? = nil,
                screen: ScreenBroadcaster? = nil,
                control: (@Sendable (ControlEvent) -> Void)? = nil,
                apps: (@Sendable () -> CompanionAppsDTO)? = nil,
                appIcon: (@Sendable (_ path: String, _ px: Int) -> Data?)? = nil,
                windows: (@Sendable () async -> CompanionWindowsDTO)? = nil,
                compactOpen: (@Sendable (CompanionCompactOpenRequestDTO) async -> CompanionCompactOpenResponseDTO?)? = nil,
                screenTarget: (@Sendable (UInt32?) -> Void)? = nil,
                screenFit: (@Sendable (UInt32, UInt32) -> Void)? = nil,
                power: (@Sendable () async -> CompanionPowerDTO)? = nil,
                wake: (@Sendable () async -> Void)? = nil,
                unlock: (@Sendable () async -> Bool)? = nil,
                privacy: (@Sendable (_ on: Bool) async -> Bool)? = nil,
                lock: (@Sendable () async -> Bool)? = nil,
                awake: (@Sendable (_ change: CompanionAwakeChangeDTO?) async -> CompanionAwakeDTO)? = nil,
                aiModels: (@Sendable () async -> Data?)? = nil,
                aiProviders: (@Sendable () async -> Data?)? = nil,
                aiChat: (@Sendable (_ body: Data, _ emit: @escaping @Sendable (Data) -> Void) async -> Void)? = nil,
                fileOps: FileOps? = nil,
                codeOps: CodeOps? = nil,
                termOps: TermOps? = nil,
                flowOps: FlowOps? = nil,
                devices: (@Sendable () async -> Data?)? = nil,
                apnsRegister: (@Sendable (_ bearer: String, _ body: Data) async -> Bool)? = nil,
                openURL: (@Sendable (_ url: String) async -> Bool)? = nil,
                agentOps: AgentOps? = nil,
                voiceTurn: (@Sendable (CompanionVoiceTurnRequestDTO) async -> CompanionVoiceTurnResponseDTO?)? = nil,
                voiceTTS: (@Sendable (String) async -> Data?)? = nil,
                audio: AudioBroadcaster? = nil,
                micOps: MicOps? = nil,
                audioStatus: (@Sendable () async -> Data?)? = nil,
                system: (@Sendable () async -> CompanionSystemDTO)? = nil,
                audioOutputs: (@Sendable () async -> CompanionAudioOutputsDTO)? = nil,
                setAudioOutput: (@Sendable (String) async -> Bool)? = nil,
                clipboardOps: ClipboardOps? = nil,
                codingAgentOps: CodingAgentOps? = nil,
                recap: (@Sendable (_ token: String, _ since: Date) async -> Data?)? = nil,
                macoTest: (@Sendable () async -> Data?)? = nil,
                macoNow: (@Sendable () async -> Data?)? = nil,
                onAudit: (@Sendable (_ token: String, _ action: String, _ detail: String?, _ via: String) -> Void)? = nil,
                onLog: @escaping @Sendable (String) -> Void,
                onListening: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 8899
        self.authorize = authorize
        self.pair = pair
        self.unpair = unpair
        self.builds = builds
        self.build = build
        self.logsSince = logsSince
        self.buildAction = buildAction
        self.installBuild = installBuild
        self.hardware = hardware
        self.pipelineOps = pipelineOps
        self.metrics = metrics
        self.screen = screen
        self.control = control
        self.apps = apps
        self.appIcon = appIcon
        self.windows = windows
        self.compactOpen = compactOpen
        self.screenTarget = screenTarget
        self.screenFit = screenFit
        self.power = power
        self.wake = wake
        self.unlock = unlock
        self.privacy = privacy
        self.lock = lock
        self.awake = awake
        self.aiModels = aiModels
        self.aiProviders = aiProviders
        self.aiChat = aiChat
        self.codeOps = codeOps
        self.termOps = termOps
        self.flowOps = flowOps
        self.devices = devices
        self.apnsRegister = apnsRegister
        self.openURL = openURL
        self.fileOps = fileOps
        self.agentOps = agentOps
        self.voiceTurn = voiceTurn
        self.voiceTTS = voiceTTS
        self.audio = audio
        self.micOps = micOps
        self.audioStatus = audioStatus
        self.system = system
        self.audioOutputs = audioOutputs
        self.setAudioOutput = setAudioOutput
        self.clipboardOps = clipboardOps
        self.codingAgentOps = codingAgentOps
        self.recap = recap
        self.macoTest = macoTest
        self.macoNow = macoNow
        self.onAudit = onAudit
        self.onLog = onLog
        self.onListening = onListening
    }

    // MARK: Lifecycle

    /// start() was called and stop() hasn't been — bind failures keep retrying
    /// while this holds. (Touched only on `queue`.)
    private var shouldRun = false

    /// One listener plus what its rebind loop needs. There are two: the TLS one
    /// facing the LAN on the configured port, and a cleartext one on loopback
    /// for cloudflared, which is already behind Cloudflare's TLS.
    private final class Endpoint {
        let name: String
        var listener: NWListener?
        var ready = false
        /// Log the "port busy, waiting" line once per wait, not every 3s.
        var loggedWaiting = false
        init(_ name: String) { self.name = name }
    }
    private let lan = Endpoint("LAN")
    private let loopback = Endpoint("loopback")

    public func start() {
        queue.async { [self] in
            guard !shouldRun else { return }
            shouldRun = true
            lan.loggedWaiting = false
            loopback.loggedWaiting = false
            bind()
        }
    }

    /// One bind attempt for each listener. A busy port (e.g. an older app
    /// instance still holding it during an update) is NOT fatal: NWListener
    /// reports it asynchronously through the state handler, so we watch for
    /// `.failed`, release, and try again every few seconds — the moment the old
    /// instance quits, this one takes over and paired devices reconnect on
    /// their own.
    private func bind() {
        guard shouldRun else { return }
        resolveLANIdentity()
        // The LAN gets TLS or it gets nothing.
        if let lanTLS {
            bind(lan, port: port, tls: lanTLS, loopbackOnly: false)
        }
        bind(loopback, port: NWEndpoint.Port(rawValue: loopbackPort) ?? port,
             tls: nil, loopbackOnly: true)
    }

    /// Resolve (and on first ever run, create) the LAN certificate. Once only:
    /// a rebind must not churn the pin, because every paired device has it.
    private func resolveLANIdentity() {
        guard !lanTLSResolved else { return }
        lanTLSResolved = true
        lanTLS = LANIdentity.loadOrCreate(log: onLog)
        pinLock.lock()
        publishedPin = lanTLS?.pin
        pinLock.unlock()
        if lanTLS == nil {
            onLog("✗ No LAN certificate, so the companion is reachable through the tunnel only. "
                  + "Serving the LAN without TLS would put the device token on the wire in the clear.")
        }
    }

    private func bind(_ endpoint: Endpoint, port: NWEndpoint.Port,
                     tls: LANIdentity.Loaded?, loopbackOnly: Bool) {
        guard shouldRun, endpoint.listener == nil else { return }
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

        var tlsOptions: NWProtocolTLS.Options?
        if let tls {
            guard let identity = sec_identity_create(tls.identity) else {
                onLog("✗ LAN TLS: the certificate could not be handed to the listener")
                return
            }
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
            // No client gets to negotiate anything older, on a link where the
            // whole point is that a passive listener learns nothing.
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
            tlsOptions = options
        }

        let params = NWParameters(tls: tlsOptions, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.serviceClass = .interactiveVideo
        // Binding the cleartext listener to 127.0.0.1 is the other half of the
        // fix: cloudflared reaches it, nothing on the Wi-Fi can.
        if loopbackOnly {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        }

        do {
            let l = loopbackOnly ? try NWListener(using: params) : try NWListener(using: params, on: port)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn, viaTunnel: loopbackOnly) }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    endpoint.loggedWaiting = false
                    endpoint.ready = true
                    let how = tls != nil ? "https" : "http, loopback only"
                    self.onLog("📡 Companion server listening on :\(port.rawValue) (\(how))")
                    self.reportListening()
                case .failed:
                    if !endpoint.loggedWaiting {
                        endpoint.loggedWaiting = true
                        self.onLog("✗ Port \(port.rawValue) is busy (another MacON still running?), waiting for it…")
                    }
                    endpoint.listener?.cancel()
                    endpoint.listener = nil
                    endpoint.ready = false
                    self.reportListening()
                    self.scheduleRebind(endpoint, port: port, tls: tls, loopbackOnly: loopbackOnly)
                default:
                    break
                }
            }
            l.start(queue: queue)
            endpoint.listener = l
        } catch {
            onLog("✗ Companion couldn't bind port \(port.rawValue): \(error.localizedDescription)")
            reportListening()
            scheduleRebind(endpoint, port: port, tls: tls, loopbackOnly: loopbackOnly)
        }
    }

    /// "Listening" for the UI means a device could reach us: over the LAN, or
    /// through the tunnel that rides the loopback listener.
    private func reportListening() {
        onListening(lan.ready || loopback.ready)
    }

    private func scheduleRebind(_ endpoint: Endpoint, port: NWEndpoint.Port,
                                tls: LANIdentity.Loaded?, loopbackOnly: Bool) {
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.bind(endpoint, port: port, tls: tls, loopbackOnly: loopbackOnly)
        }
    }

    public func stop() {
        queue.async { [self] in
            shouldRun = false                 // also parks any pending rebind
            for endpoint in [lan, loopback] {
                endpoint.listener?.cancel()
                endpoint.listener = nil
                endpoint.ready = false
            }
            onListening(false)
        }
    }

    // MARK: Request lifecycle

    // Caps on a request that has not been authenticated yet. Anyone who reaches
    // the tunnel URL can open a connection and start sending, and the buffer
    // holding a request while it arrives is filled before routing and before the
    // bearer gate. So it has to be bounded here, not by the routes.

    /// Ceiling on one request body. /clipboard accepts 16 MB at the app layer
    /// and base64 inside JSON inflates that by a third, so this fits the largest
    /// legitimate payload (a clipboard image) and little else.
    private static let maxBodyBytes = 32 * 1024 * 1024
    /// Ceiling on the header block on its own. Real requests are a few KB.
    private static let maxHeaderBytes = 64 * 1024
    /// Headers have to finish arriving inside this, so a sender that never sends
    /// the blank line cannot hold a socket for ever.
    private static let headerDeadline: TimeInterval = 30
    /// How often the watchdog checks a request is still making progress.
    private static let progressInterval: TimeInterval = 10

    /// One request while it is still arriving. Touched only on `queue`, which is
    /// serial, so it needs no locking of its own.
    private final class Incoming {
        var buffer = Data()
        /// How far we have already looked for the header terminator, so a large
        /// body is not rescanned from byte zero on every read.
        var scanned = 0
        var headerComplete = false
        /// Buffer size at the last watchdog tick, to spot a stalled sender.
        var mark = 0
        /// Set once the request reaches `route`, which stands the watchdog down:
        /// past that point a WebSocket upgrade owns the connection and may sit
        /// idle for as long as it likes.
        var routed = false
        let started = Date()
        /// Came in on the loopback listener, i.e. through cloudflared.
        var viaTunnel = false
    }

    private func accept(_ conn: NWConnection, viaTunnel: Bool) {
        conn.start(queue: queue)
        let incoming = Incoming()
        incoming.viaTunnel = viaTunnel
        watchProgress(conn, incoming)
        readRequest(conn, incoming)
    }

    /// Drop a connection that stalls before it is routed. Without this a trickle
    /// of a byte at a time keeps a socket, and the buffer behind it, alive.
    private func watchProgress(_ conn: NWConnection, _ incoming: Incoming) {
        queue.asyncAfter(deadline: .now() + Self.progressInterval) { [weak self] in
            guard !incoming.routed else { return }
            guard let self else { conn.cancel(); return }
            if !incoming.headerComplete,
               Date().timeIntervalSince(incoming.started) > Self.headerDeadline {
                conn.cancel(); return
            }
            guard incoming.buffer.count > incoming.mark else { conn.cancel(); return }
            incoming.mark = incoming.buffer.count
            self.watchProgress(conn, incoming)
        }
    }

    /// Accumulate until the full header block (and any POST body) has arrived,
    /// refusing anything that grows past the caps above.
    private func readRequest(_ conn: NWConnection, _ incoming: Incoming) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            if let data, !data.isEmpty { incoming.buffer.append(data) }

            guard let sep = self.headerTerminator(in: incoming) else {
                // Still inside the header block. Nothing legitimate is this big,
                // so a buffer past the cap means the terminator is being withheld.
                if incoming.buffer.count > Self.maxHeaderBytes {
                    self.respond(conn, "431 Request Header Fields Too Large", json: nil); return
                }
                if isComplete || error != nil { conn.cancel() } else { self.readRequest(conn, incoming) }
                return
            }
            incoming.headerComplete = true

            let header = String(data: incoming.buffer.subdata(in: incoming.buffer.startIndex..<sep.lowerBound),
                                encoding: .utf8) ?? ""
            let contentLength = self.headerInt(header, "content-length") ?? 0
            // Refuse on the declared length, before a byte of the body is kept.
            if contentLength > Self.maxBodyBytes {
                self.respond(conn, "413 Payload Too Large", json: nil); return
            }
            let have = incoming.buffer.distance(from: sep.upperBound, to: incoming.buffer.endIndex)
            if have < contentLength && !isComplete && error == nil {
                // And on what actually arrives, for a sender that under-declares.
                if have > Self.maxBodyBytes {
                    self.respond(conn, "413 Payload Too Large", json: nil); return
                }
                self.readRequest(conn, incoming); return
            }
            incoming.routed = true
            let body = incoming.buffer.subdata(in: sep.upperBound..<incoming.buffer.endIndex)
            self.route(conn, header: header, body: body, via: incoming.viaTunnel ? "tunnel" : "lan")
        }
    }

    /// The `\r\n\r\n` that ends the header block, resuming the search where the
    /// last read stopped (less the three bytes a split terminator needs). Without
    /// the resume, a 32 MB body is scanned from the start on every read, which is
    /// its own denial of service.
    private func headerTerminator(in incoming: Incoming) -> Range<Data.Index>? {
        let buffer = incoming.buffer
        let from = buffer.index(buffer.startIndex, offsetBy: incoming.scanned)
        if let found = buffer.range(of: Data("\r\n\r\n".utf8), in: from..<buffer.endIndex) { return found }
        incoming.scanned = max(0, buffer.count - 3)
        return nil
    }

    private func route(_ conn: NWConnection, header: String, body: Data, via: String) {
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
                      var resp = await self.pair(req.code, req.deviceName) else {
                    self.respond(conn, "401 Unauthorized", json: nil); return
                }
                // Hand over the LAN certificate to expect, so the device pins it
                // from this moment on. Pairing itself has either come through the
                // tunnel, or over this very TLS connection on first sight.
                resp.lanCertSha256 = self.lanCertPin
                self.onAudit?(resp.token, "paired", req.deviceName, via)
                self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(resp))
            }
            return
        }

        // Everything else needs a valid bearer token.
        guard let token = bearer(header), authorize(token) else {
            respond(conn, "401 Unauthorized", json: nil); return
        }

        // The audit line, decided in one place from the request's shape so no
        // route can forget it. Reads and a device's own housekeeping are not
        // in the list.
        if let onAudit {
            let isUpgrade = headerValue(header, "upgrade")?.lowercased() == "websocket"
            if let hit = AuditLog.action(method: method, path: rawPath, segs: segs, isUpgrade: isUpgrade, body: body) {
                onAudit(token, hit.action, hit.detail, via)
            }
        }

        // POST /unpair — the calling device ends its own pairing. Its token is
        // revoked here, so the Mac's paired-devices list updates the moment
        // the device forgets it (not whenever someone next opens Settings).
        if method == "POST", path == "/unpair" {
            guard let unpair else { respond(conn, "404 Not Found", json: nil); return }
            Task {
                let ok = await unpair(token)
                self.respond(conn, ok ? "200 OK" : "404 Not Found", json: nil)
            }
            return
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

        // GET /lan — the port and exact certificate to expect on a direct LAN
        // connection. Authenticated, so a device that paired before LAN TLS
        // existed can learn the pin over the tunnel rather than being re-paired.
        if method == "GET", path == "/lan" {
            let dto = CompanionLANDTO(port: Int(self.port.rawValue), certSha256: lanCertPin)
            respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(dto))
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
        // reverts to the whole display. ?fit=WxH is the device's screen in
        // pixels, so the Mac can shape its virtual display to the device.
        // One capture pipeline — last viewer wins.
        if method == "GET", path == "/screen",
           headerValue(header, "upgrade")?.lowercased() == "websocket" {
            guard screen != nil else { respond(conn, "404 Not Found", json: nil); return }
            screenTarget?(query["window"].flatMap { UInt32($0) })
            let fit = query["fit"]?.split(separator: "x").compactMap { UInt32($0) } ?? []
            screenFit?(fit.count == 2 ? fit[0] : 0, fit.count == 2 ? fit[1] : 0)
            upgradeAndStreamScreen(conn, header: header); return
        }

        // POST /screen/claim — "move screen here": this device becomes the sole
        // viewer; the others watching are evicted.
        if method == "POST", segs.count == 2, segs[0] == "screen", segs[1] == "claim" {
            guard screen != nil else { respond(conn, "404 Not Found", json: nil); return }
            claimScreen(for: token)
            respond(conn, "200 OK", json: nil); return
        }

        // WS /control — remote input events, iPad → Mac
        if method == "GET", path == "/control",
           headerValue(header, "upgrade")?.lowercased() == "websocket" {
            guard control != nil else { respond(conn, "404 Not Found", json: nil); return }
            upgradeAndControl(conn, header: header); return
        }

        // WS /audio — encoded Mac system audio, Mac → device ("hear Mac here").
        if method == "GET", path == "/audio",
           headerValue(header, "upgrade")?.lowercased() == "websocket" {
            guard audio != nil else { respond(conn, "404 Not Found", json: nil); return }
            upgradeAndStreamAudio(conn, header: header); return
        }

        // WS /mic — encoded device microphone, device → Mac ("talk to Mac").
        if method == "GET", path == "/mic",
           headerValue(header, "upgrade")?.lowercased() == "websocket" {
            guard micOps != nil else { respond(conn, "404 Not Found", json: nil); return }
            upgradeAndMic(conn, header: header); return
        }

        // GET /audio/status — driver + consent state behind the media-I/O
        // toggles, so the device can hint "install the driver" vs "sharing off".
        if method == "GET", path == "/audio/status" {
            guard let audioStatus else { respond(conn, "404 Not Found", json: nil); return }
            Task { self.respond(conn, "200 OK", json: await audioStatus()) }
            return
        }

        // GET /system — the Mac's vitals (CPU, memory, disk, battery, thermal)
        // for the deck's live tiles. Polled, so everything behind it is cheap.
        if method == "GET", path == "/system" {
            guard let system else { respond(conn, "404 Not Found", json: nil); return }
            Task { self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(await system())) }
            return
        }

        // GET /audio/outputs — where the Mac can play, and where it is playing.
        if method == "GET", path == "/audio/outputs" {
            guard let audioOutputs else { respond(conn, "404 Not Found", json: nil); return }
            Task { self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(await audioOutputs())) }
            return
        }

        // POST /audio/output {"uid": …} — switch the default output device.
        if method == "POST", path == "/audio/output" {
            guard let setAudioOutput else { respond(conn, "404 Not Found", json: nil); return }
            guard let req = try? CompanionJSON.decoder.decode(CompanionAudioOutputSetDTO.self, from: body) else {
                respond(conn, "400 Bad Request", json: nil); return
            }
            Task {
                let ok = await setAudioOutput(req.uid)
                self.respond(conn, ok ? "200 OK" : "404 Not Found", json: nil)
            }
            return
        }

        // GET /clipboard?after=N — the Mac's latest clipboard item (universal
        // copy & paste). reps come back empty when nothing is newer than N.
        if method == "GET", path == "/clipboard" {
            guard let ops = clipboardOps else { respond(conn, "404 Not Found", json: nil); return }
            let after = Int(query["after"] ?? "") ?? -1
            Task {
                if let data = await ops.latest(after) {
                    self.respond(conn, "200 OK", json: data)
                } else { self.respond(conn, "403 Forbidden", json: nil) }
            }
            return
        }

        // POST /clipboard — a device's clipboard becomes the Mac's (and is
        // offered to every other paired device on their next poll).
        if method == "POST", path == "/clipboard" {
            guard let ops = clipboardOps else { respond(conn, "404 Not Found", json: nil); return }
            Task {
                if let ack = await ops.push(body) {
                    self.respond(conn, "200 OK", json: ack)
                } else { self.respond(conn, "403 Forbidden", json: nil) }
            }
            return
        }

        // GET /recap?since=T — what happened since the device last looked.
        // A missing or silly T means the last eight hours; nothing older than
        // the journal's week is kept anyway.
        if method == "GET", path == "/recap" {
            guard let recap else { respond(conn, "404 Not Found", json: nil); return }
            let now = Date()
            let asked = Double(query["since"] ?? "").map { Date(timeIntervalSince1970: $0) }
            let since = min(now, max(asked ?? now.addingTimeInterval(-8 * 3600),
                                     now.addingTimeInterval(-7 * 24 * 3600)))
            Task {
                if let data = await recap(token, since) {
                    self.respond(conn, "200 OK", json: data)
                } else { self.respond(conn, "403 Forbidden", json: nil) }
            }
            return
        }

        // GET /maco — the mood the Lock Screen card would show, asked for
        // while Maco's room is open. {} when there is nothing going on.
        if method == "GET", path == "/maco" {
            guard let macoNow else { respond(conn, "404 Not Found", json: nil); return }
            Task { self.respond(conn, "200 OK", json: await macoNow()) }
            return
        }

        // POST /maco/test — every mood in turn on the devices showing Maco,
        // through the real push path. `macon maco test` calls it.
        if method == "POST", path == "/maco/test" {
            guard let macoTest else { respond(conn, "404 Not Found", json: nil); return }
            Task {
                if let data = await macoTest() {
                    self.respond(conn, "200 OK", json: data)
                } else { self.respond(conn, "409 Conflict", json: nil) }
            }
            return
        }

        // /coding-agents — Claude Code / Codex sessions on this Mac.
        if segs.first == "coding-agents" {
            guard let ops = codingAgentOps else { respond(conn, "404 Not Found", json: nil); return }

            // POST /coding-agents/hook — a hook reports a moment. Any paired
            // token may (the CLI self-pairs); this is the agent talking, not a
            // device acting on the Mac.
            if method == "POST", segs.count == 2, segs[1] == "hook" {
                guard let event = try? CompanionJSON.decoder.decode(CodingAgentHookEvent.self, from: body) else {
                    respond(conn, "400 Bad Request", json: nil); return
                }
                Task {
                    let resp = await ops.hook(event)
                    self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(resp))
                }
                return
            }

            // GET /coding-agents — the sessions (403 when the toggle is off).
            if method == "GET", segs.count == 1 {
                Task {
                    if let dto = await ops.list() {
                        self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(dto))
                    } else { self.respond(conn, "403 Forbidden", json: nil) }
                }
                return
            }

            // GET /coding-agents/{id} — one session and what it has been doing.
            if method == "GET", segs.count == 2, segs[1] != "hook" {
                let id = segs[1]
                Task {
                    if let dto = await ops.detail(id) {
                        self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(dto))
                    } else if await ops.list() == nil {
                        self.respond(conn, "403 Forbidden", json: nil)
                    } else { self.respond(conn, "404 Not Found", json: nil) }
                }
                return
            }

            // GET /coding-agents/{id}/decision?seq=N&wait=S — the hook waits
            // for a device's answer. The reply carries the answer when one
            // arrived inside the wait, and `hold`, which turns false the
            // moment somebody is back at the Mac.
            if method == "GET", segs.count == 3, segs[2] == "decision" {
                let id = segs[1]
                guard let seq = Int(query["seq"] ?? "") else { respond(conn, "400 Bad Request", json: nil); return }
                let wait = TimeInterval(Int(query["wait"] ?? "") ?? 10)
                Task {
                    let reply = await ops.waitDecision(id, seq, wait)
                    self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(reply))
                }
                return
            }

            // POST /coding-agents/{id}/decision {seq, allow, message?}
            if method == "POST", segs.count == 3, segs[2] == "decision" {
                guard let decision = try? CompanionJSON.decoder.decode(CompanionCodingAgentDecisionDTO.self, from: body) else {
                    respond(conn, "400 Bad Request", json: nil); return
                }
                let id = segs[1]
                Task {
                    switch await ops.decide(id, decision) {
                    case .some(true):  self.respond(conn, "200 OK", json: nil)
                    case .some(false): self.respond(conn, "404 Not Found", json: nil)
                    case .none:        self.respond(conn, "403 Forbidden", json: nil)
                    }
                }
                return
            }

            // DELETE /coding-agents/{id} — forget a session.
            if method == "DELETE", segs.count == 2 {
                let id = segs[1]
                Task {
                    let ok = await ops.remove(id)
                    self.respond(conn, ok ? "200 OK" : "404 Not Found", json: nil)
                }
                return
            }

            respond(conn, "404 Not Found", json: nil)
            return
        }

        // GET /apps — installed Mac apps for the shortcut deck (control-only).
        // GET /apps/icon?path=/Applications/X.app&px=128 — one icon as PNG.
        // Fetched per row by the phone, so the list itself stays a few KB.
        if method == "GET", path == "/apps/icon" {
            guard let appIcon, let target = query["path"], !target.isEmpty else {
                respond(conn, "404 Not Found", json: nil); return
            }
            let px = max(32, min(512, Int(query["px"] ?? "") ?? 128))
            Task {
                if let png = appIcon(target, px) {
                    self.respondData(conn, "200 OK", contentType: "image/png", data: png)
                } else {
                    self.respond(conn, "404 Not Found", json: nil)
                }
            }
            return
        }

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

        // POST /control/once — one control event, applied and answered. The
        // WebSocket at /control is right for a device that is driving the Mac
        // continuously; a watch firing a single shortcut should not have to
        // hold a socket open to do it. Same `control` sink, so the same
        // allowControl gate decides, and the same events are understood.
        if method == "POST", segs.count == 2, segs[0] == "control", segs[1] == "once" {
            guard let control else { respond(conn, "404 Not Found", json: nil); return }
            guard let event = try? CompanionJSON.decoder.decode(ControlEvent.self, from: body) else {
                respond(conn, "400 Bad Request", json: nil); return
            }
            control(event)
            respond(conn, "200 OK", json: nil)
            return
        }

        // POST /open — open a web address in the Mac's default browser. Body
        // {"url": "https://…"}; http(s) only. Remote control must be on.
        if method == "POST", path == "/open" {
            guard let openURL else { respond(conn, "404 Not Found", json: nil); return }
            struct Body: Decodable { var url: String }
            guard let b = try? CompanionJSON.decoder.decode(Body.self, from: body),
                  let url = URL(string: b.url),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                respond(conn, "400 Bad Request", json: nil); return
            }
            Task {
                let ok = await openURL(b.url)
                self.respond(conn, ok ? "200 OK" : "403 Forbidden", json: nil)
            }
            return
        }

        // GET/POST /pro/meter — the free tier's 40 minutes a day of remote
        // time, kept on this Mac so every paired device shares one count and
        // the day rolls over at this Mac's midnight. GET reads it; POST adds
        // {"seconds": n} and reads it back. Pro companions never call it.
        if segs.count == 2, segs[0] == "pro", segs[1] == "meter", method == "GET" || method == "POST" {
            var add = 0
            if method == "POST" {
                struct Report: Decodable { var seconds: Int }
                guard let report = try? CompanionJSON.decoder.decode(Report.self, from: body) else {
                    respond(conn, "400 Bad Request", json: nil); return
                }
                add = report.seconds
            }
            let ledger = remoteMeter
            Task {
                let info = add > 0 ? await ledger.add(seconds: add) : await ledger.info()
                self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(info))
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
        // POST /agent/eager — the user is mid-sentence; if what they've said so
        // far names an app, open it now. Answers fast and never blocks on a model.
        if method == "POST", segs.count == 2, segs[0] == "agent", segs[1] == "eager" {
            guard let agentOps else { respond(conn, "404 Not Found", json: nil); return }
            guard let req = try? CompanionJSON.decoder.decode(CompanionAgentEagerRequestDTO.self, from: body) else {
                respond(conn, "400 Bad Request", json: nil); return
            }
            Task {
                if let resp = await agentOps.eager(req) {
                    self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(resp))
                } else {
                    self.respond(conn, "409 Conflict", json: nil)
                }
            }
            return
        }

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

        // GET /power/awake — the awake timer and heat guard.
        // POST /power/awake — change them (CompanionAwakeChangeDTO), reads back.
        if segs.count == 2, segs[0] == "power", segs[1] == "awake", method == "GET" || method == "POST" {
            guard let awake else { respond(conn, "404 Not Found", json: nil); return }
            var change: CompanionAwakeChangeDTO?
            if method == "POST" {
                guard let c = try? CompanionJSON.decoder.decode(CompanionAwakeChangeDTO.self, from: body) else {
                    respond(conn, "400 Bad Request", json: nil); return
                }
                change = c
            }
            Task { self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(await awake(change))) }
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

        // GET /ai/providers — custom OpenAI-compatible providers (no keys).
        if method == "GET", path == "/ai/providers" {
            guard let aiProviders else { respond(conn, "404 Not Found", json: nil); return }
            Task {
                if let data = await aiProviders() { self.respond(conn, "200 OK", json: data) }
                else { self.respond(conn, "503 Service Unavailable", json: nil) }
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

        // POST /voice/turn — one live-voice conversation turn → { say, task? }.
        if method == "POST", path == "/voice/turn" {
            guard let voiceTurn else { respond(conn, "404 Not Found", json: nil); return }
            guard let req = try? CompanionJSON.decoder.decode(CompanionVoiceTurnRequestDTO.self, from: body) else {
                respond(conn, "400 Bad Request", json: nil); return
            }
            Task {
                if let resp = await voiceTurn(req) {
                    self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(resp))
                } else {
                    self.respond(conn, "503 Service Unavailable", json: nil)
                }
            }
            return
        }

        // POST /voice/tts — synthesize a reply → WAV (503 = no TTS on the Mac,
        // the device speaks with its own voice instead).
        if method == "POST", path == "/voice/tts" {
            guard let voiceTTS else { respond(conn, "404 Not Found", json: nil); return }
            guard let req = try? CompanionJSON.decoder.decode(CompanionVoiceTTSRequestDTO.self, from: body),
                  !req.text.isEmpty else {
                respond(conn, "400 Bad Request", json: nil); return
            }
            Task {
                if let wav = await voiceTTS(req.text) {
                    self.respondData(conn, "200 OK", contentType: "audio/wav", data: wav)
                } else {
                    self.respond(conn, "503 Service Unavailable", json: nil)
                }
            }
            return
        }

        // WS /term?cwd= — a live shell (PTY) on the Mac for the Code terminal.
        if method == "GET", path == "/term",
           headerValue(header, "upgrade")?.lowercased() == "websocket" {
            guard termOps != nil else { respond(conn, "404 Not Found", json: nil); return }
            upgradeAndTerm(conn, header: header, cwd: query["cwd"],
                           session: query["session"], persist: query["persist"] == "1"); return
        }

        // /code — native file browsing/editing for the companion's Code screen.
        // /files/* — the Mac's home folder for a paired device's Files app.
        // Same home sandbox and same toggle as /code; this one carries every
        // file type and can create, move and delete.
        if segs.first == "files" {
            guard let fileOps else { respond(conn, "404 Not Found", json: nil); return }

            // GET /files/list?path= — a directory (path empty = home).
            if method == "GET", segs.count == 2, segs[1] == "list" {
                let path = query["path"] ?? "~"
                Task {
                    if let dto = await fileOps.list(path) {
                        self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(dto))
                    } else { self.respond(conn, "403 Forbidden", json: nil) }
                }
                return
            }

            // GET /files/item?path= — one item's metadata, for a refresh.
            if method == "GET", segs.count == 2, segs[1] == "item" {
                guard let path = query["path"] else { respond(conn, "400 Bad Request", json: nil); return }
                Task {
                    if let dto = await fileOps.item(path) {
                        self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(dto))
                    } else { self.respond(conn, "404 Not Found", json: nil) }
                }
                return
            }

            // GET /files/blob?path= — the raw bytes, whatever kind of file.
            if method == "GET", segs.count == 2, segs[1] == "blob" {
                guard let path = query["path"] else { respond(conn, "400 Bad Request", json: nil); return }
                Task {
                    if let data = await fileOps.read(path) {
                        self.respondData(conn, "200 OK", contentType: "application/octet-stream", data: data)
                    } else { self.respond(conn, "404 Not Found", json: nil) }
                }
                return
            }

            // PUT /files/blob?path= — write the body, creating if needed.
            if method == "PUT", segs.count == 2, segs[1] == "blob" {
                guard let path = query["path"] else { respond(conn, "400 Bad Request", json: nil); return }
                Task {
                    if let dto = await fileOps.write(path, body) {
                        self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(dto))
                    } else { self.respond(conn, "403 Forbidden", json: nil) }
                }
                return
            }

            // POST /files/mkdir  {"path": "~/New Folder"}
            if method == "POST", segs.count == 2, segs[1] == "mkdir" {
                struct Body: Decodable { var path: String }
                guard let b = try? CompanionJSON.decoder.decode(Body.self, from: body) else {
                    respond(conn, "400 Bad Request", json: nil); return
                }
                Task {
                    if let dto = await fileOps.makeDirectory(b.path) {
                        self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(dto))
                    } else { self.respond(conn, "403 Forbidden", json: nil) }
                }
                return
            }

            // POST /files/delete  {"path": "~/x"} — to the Trash, not gone.
            if method == "POST", segs.count == 2, segs[1] == "delete" {
                struct Body: Decodable { var path: String }
                guard let b = try? CompanionJSON.decoder.decode(Body.self, from: body) else {
                    respond(conn, "400 Bad Request", json: nil); return
                }
                Task {
                    let ok = await fileOps.delete(b.path)
                    self.respond(conn, ok ? "200 OK" : "403 Forbidden", json: nil)
                }
                return
            }

            // POST /files/move  {"from": "~/a", "to": "~/b"} — rename or move.
            if method == "POST", segs.count == 2, segs[1] == "move" {
                struct Body: Decodable { var from: String; var to: String }
                guard let b = try? CompanionJSON.decoder.decode(Body.self, from: body) else {
                    respond(conn, "400 Bad Request", json: nil); return
                }
                Task {
                    if let dto = await fileOps.move(b.from, b.to) {
                        self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(dto))
                    } else { self.respond(conn, "403 Forbidden", json: nil) }
                }
                return
            }

            respond(conn, "404 Not Found", json: nil)
            return
        }

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

        // POST /builds/{id}/install {"device": …} — the app this run built,
        // onto a real device. Long: devicectl can take a minute over Wi-Fi.
        if method == "POST", segs.count == 3, segs[0] == "builds", segs[2] == "install" {
            guard let installBuild else { respond(conn, "404 Not Found", json: nil); return }
            struct Body: Decodable { var device: String }
            guard let b = try? CompanionJSON.decoder.decode(Body.self, from: body) else {
                respond(conn, "400 Bad Request", json: nil); return
            }
            let id = segs[1]
            Task {
                if let result = await installBuild(id, b.device) {
                    self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(result))
                } else { self.respond(conn, "404 Not Found", json: nil) }
            }
            return
        }

        // GET /hardware — iPhones, iPads and the rest Xcode has paired.
        if method == "GET", path == "/hardware" {
            guard let hardware else { respond(conn, "404 Not Found", json: nil); return }
            Task { self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(await hardware())) }
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

    /// A binary response (e.g. synthesized speech).
    private func respondData(_ conn: NWConnection, _ status: String, contentType: String, data: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(data.count)\r\n"
        head += "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in conn.cancel() })
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
        let token = bearer(header) ?? ""
        let state = WSState()
        state.onClose = { [weak self] in
            broadcaster.removeViewer(id)
            guard let self else { return }
            self.screenLock.lock(); self.screenViewers[id] = nil; self.screenLock.unlock()
            self.broadcastScreenCount()
        }
        screenLock.lock(); screenViewers[id] = ScreenViewer(conn: conn, token: token, state: state); screenLock.unlock()

        conn.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.drainClient(conn, state: state)
            self.broadcastScreenCount()
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
                conn.send(content: frame, completion: .contentProcessed { error in
                    state.sendLock.lock(); state.inflightBytes -= packet.count; state.sendLock.unlock()
                    // A dead peer (slept Mac's old socket, vanished Wi-Fi)
                    // errors here long before keepalive notices — reap it NOW,
                    // or the corpse keeps occupying the viewer list and the
                    // next reconnect never triggers a capture (re)start.
                    if error != nil, state.open {
                        state.open = false
                        state.onClose?(); state.onClose = nil
                        conn.cancel()
                    }
                })
            }
        })
    }

    /// Tell every screen viewer how many devices are currently watching, as a
    /// JSON text frame `{"viewers": N}` — the client shows a "Move screen here"
    /// affordance when that's ≥ 2.
    private func broadcastScreenCount() {
        screenLock.lock(); let viewers = Array(screenViewers.values); screenLock.unlock()
        guard let json = try? JSONSerialization.data(withJSONObject: ["viewers": viewers.count]) else { return }
        for v in viewers {
            guard let conn = v.conn, v.state.open else { continue }
            send(conn, payload: json, opcode: 0x81)
        }
    }

    /// "Move screen here": the caller's device becomes the sole viewer by
    /// evicting the others (they get an `{"evicted": true}` frame, then close).
    private func claimScreen(for token: String) {
        screenLock.lock()
        let others = screenViewers.filter { $0.value.token != token }
        for id in others.keys { screenViewers[id] = nil }
        screenLock.unlock()

        guard let bye = try? JSONSerialization.data(withJSONObject: ["evicted": true]) else { return }
        for (id, v) in others {
            screen?.removeViewer(id)
            guard let conn = v.conn else { continue }
            send(conn, payload: bye, opcode: 0x81)
            v.state.open = false
            queue.asyncAfter(deadline: .now() + 0.15) { conn.cancel() }   // let the frame flush
        }
        broadcastScreenCount()
    }

    // MARK: Audio streaming

    /// Upgrade to WebSocket and push encoded audio packets from the broadcaster.
    /// Same shape as the screen path with a much smaller in-flight budget and no
    /// keyframe dance — every AAC packet decodes on its own, so when the link
    /// clogs we just drop packets (a 21 ms blip) until it drains.
    private func upgradeAndStreamAudio(_ conn: NWConnection, header: String) {
        guard let broadcaster = audio else { respond(conn, "404 Not Found", json: nil); return }
        guard let key = headerValue(header, "sec-websocket-key") else { respond(conn, "400 Bad Request", json: nil); return }
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data((key + magic).utf8))).base64EncodedString()
        let handshake = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"

        let id = ObjectIdentifier(conn)
        let state = WSState()
        state.onClose = { broadcaster.removeListener(id) }

        conn.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.drainClient(conn, state: state)
            // ~64 kbps stream: 64 KB in flight ≈ 8 s of audio — hit only when
            // the transport truly stalls, at which point dropping is right.
            let budget = 64 * 1024
            broadcaster.addListener(id) { [weak conn] packet in
                guard let conn, state.open else { return }
                state.sendLock.lock()
                if state.inflightBytes > budget {
                    state.sendLock.unlock()
                    return                              // drop; decoder rides through
                }
                state.inflightBytes += packet.count
                state.sendLock.unlock()

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
                conn.send(content: frame, completion: .contentProcessed { error in
                    state.sendLock.lock(); state.inflightBytes -= packet.count; state.sendLock.unlock()
                    // Same dead-peer reaping as the screen path: a zombie
                    // listener would pin capture on and block the restart.
                    if error != nil, state.open {
                        state.open = false
                        state.onClose?(); state.onClose = nil
                        conn.cancel()
                    }
                })
            }
        })
    }

    // MARK: Remote microphone (inbound)

    /// Upgrade to WebSocket and feed inbound encoded mic packets to the app.
    /// One live source: a second device taking the mic evicts the first, the
    /// same last-device-wins rule as the screen session.
    private func upgradeAndMic(_ conn: NWConnection, header: String) {
        guard let ops = micOps else { respond(conn, "404 Not Found", json: nil); return }
        guard let key = headerValue(header, "sec-websocket-key") else { respond(conn, "400 Bad Request", json: nil); return }
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data((key + magic).utf8))).base64EncodedString()
        let handshake = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"

        let state = WSState()

        // Evict the previous source (if any) and become the live one.
        micLock.lock()
        let evictedConn = micConn
        let evictedState = micState
        let hadSource = micConn != nil
        micConn = conn
        micState = state
        micLock.unlock()
        if let evictedState { evictedState.open = false }
        evictedConn?.cancel()

        state.onClose = { [weak self, weak conn] in
            guard let self else { return }
            self.micLock.lock()
            // Only deactivate if WE are still the live source (not evicted).
            let isCurrent = self.micConn === conn
            if isCurrent { self.micConn = nil; self.micState = nil }
            self.micLock.unlock()
            if isCurrent { ops.onActive(false) }
        }

        conn.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            if !hadSource { ops.onActive(true) }
            self.readMic(conn, buffer: Data(), state: state, ops: ops)
        })
    }

    private func readMic(_ conn: NWConnection, buffer: Data, state: WSState, ops: MicOps) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var acc = buffer
            if let data, !data.isEmpty { acc.append(data) }
            let leftover = self.parseFrames(acc, conn: conn) { payload in
                guard state.open else { return }
                ops.packet(payload)
            }
            if isComplete || error != nil || !state.open {
                state.open = false
                state.onClose?(); state.onClose = nil
                conn.cancel(); return
            }
            self.readMic(conn, buffer: leftover, state: state, ops: ops)
        }
    }

    // MARK: Terminal (bidirectional)

    /// Upgrade to WebSocket and bridge a PTY session: raw shell output goes
    /// out as binary frames; JSON text frames carry keystrokes and resizes in.
    private func upgradeAndTerm(_ conn: NWConnection, header: String, cwd: String?,
                                session: String? = nil, persist: Bool = false) {
        guard let ops = termOps else { respond(conn, "404 Not Found", json: nil); return }
        guard let key = headerValue(header, "sec-websocket-key") else { respond(conn, "400 Bad Request", json: nil); return }
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data((key + magic).utf8))).base64EncodedString()
        let handshake = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"

        // The client may bring its own id — that's what lets it reattach to a
        // shell it left behind. Constrained to UUID shape so a crafted query
        // can't address anything else. No id = the old one-shot behavior.
        let sessionID = session.flatMap { UUID(uuidString: $0)?.uuidString } ?? UUID().uuidString
        let state = WSState()
        // Detach, not close: the ops layer decides whether the session dies
        // with the socket (default) or waits for its owner (persistent).
        state.onClose = { Task { await ops.detach(sessionID) } }

        conn.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            Task {
                // Output path: PTY bytes → binary frames, straight to the socket.
                let started = await ops.start(sessionID, cwd, persist) { [weak conn] bytes in
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
                case "kill":
                    // The client is closing this tab for good — a persistent
                    // session must die NOW, not linger detached for hours.
                    Task { await ops.close(id) }
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
            if isComplete || error != nil {
                // The socket dropped mid-session (app backgrounded, network
                // blip). Any modifier the device was holding would stay held
                // forever — release everything.
                self.control?(ControlEvent(t: "keyreset"))
                conn.cancel(); return
            }
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
            case 0x8:                                                     // close
                control?(ControlEvent(t: "keyreset"))                     // drop held modifiers
                conn.cancel(); return Data()
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
