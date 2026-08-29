//
//  CompanionModels.swift
//  MaconKit
//
//  Wire types for the iOS/iPadOS companion app. These are the exact JSON shapes
//  the app decodes — see MacON_Companion/README.md for the contract. Kept
//  separate from the internal run models so the two can evolve independently.
//

import Foundation

/// `GET /builds` response.
public struct CompanionBuildsDTO: Codable, Sendable {
    public var runnerName: String
    public var builds: [CompanionBuildDTO]
}

/// One pipeline run, as the app sees it.
public struct CompanionBuildDTO: Codable, Sendable {
    public var id: String
    public var repo: String
    public var branch: String
    public var commit: String
    public var message: String?
    public var status: String            // queued|running|passed|failed|cancelled
    public var startedAt: Date?
    public var finishedAt: Date?
    public var currentStep: String?
    public var steps: [CompanionStepDTO]?
}

public struct CompanionStepDTO: Codable, Sendable {
    public var id: String
    public var name: String
    public var status: String
}

/// One line pushed over the log WebSocket.
public struct CompanionLogDTO: Codable, Sendable {
    public var seq: Int
    public var text: String
    public var level: String?            // "info" | "error"
    public var date: Date?               // for per-step durations in the app
}

/// `GET /pipelines` response — the runner's configured pipelines, so a paired
/// device can manage them like the Mac app does.
public struct CompanionPipelinesDTO: Codable, Sendable {
    public var pipelines: [CompanionPipelineDTO]
    /// Whether this server supports add/edit/delete (the app does; a headless
    /// CLI watching a fixed config is view/run/watch only).
    public var managed: Bool
    public init(pipelines: [CompanionPipelineDTO], managed: Bool = true) {
        self.pipelines = pipelines; self.managed = managed
    }
}

/// One pipeline: its editable config plus (server → app) runtime state.
/// The same shape is accepted back on POST /pipelines and PUT /pipelines/{id};
/// runtime fields are ignored there.
public struct CompanionPipelineDTO: Codable, Sendable {
    public var id: String
    public var name: String
    public var provider: String          // bitbucket | github
    public var workspace: String
    public var repoSlug: String
    public var branch: String
    public var watchMode: String         // branch | pullRequests
    public var prTargetBranch: String
    public var pipelineFile: String
    public var workflow: String
    public var buildCommand: String
    public var triggerMode: String       // polling | webhook
    public var pollSeconds: Int
    public var webhookPort: Int
    public var buildTimeoutSeconds: Int
    public var postStatus: Bool
    // Runtime state — populated by the server, ignored on create/update.
    public var isWatching: Bool?
    public var isBuilding: Bool?
    public var state: String?            // idle | running | passed | failed

    public init(id: String, name: String, provider: String, workspace: String,
                repoSlug: String, branch: String, watchMode: String, prTargetBranch: String,
                pipelineFile: String, workflow: String, buildCommand: String,
                triggerMode: String, pollSeconds: Int, webhookPort: Int,
                buildTimeoutSeconds: Int, postStatus: Bool,
                isWatching: Bool? = nil, isBuilding: Bool? = nil, state: String? = nil) {
        self.id = id; self.name = name; self.provider = provider; self.workspace = workspace
        self.repoSlug = repoSlug; self.branch = branch; self.watchMode = watchMode
        self.prTargetBranch = prTargetBranch; self.pipelineFile = pipelineFile
        self.workflow = workflow; self.buildCommand = buildCommand
        self.triggerMode = triggerMode; self.pollSeconds = pollSeconds
        self.webhookPort = webhookPort; self.buildTimeoutSeconds = buildTimeoutSeconds
        self.postStatus = postStatus
        self.isWatching = isWatching; self.isBuilding = isBuilding; self.state = state
    }
}

/// `GET /apps` response — installed Mac apps, for the companion's shortcut deck.
public struct CompanionAppsDTO: Codable, Sendable {
    public var apps: [CompanionAppDTO]
    public init(apps: [CompanionAppDTO]) { self.apps = apps }
}

public struct CompanionAppDTO: Codable, Sendable {
    public var name: String
    public var path: String
    public var icon: String?     // base64 PNG (app supplies via AppKit); nil headless
    public init(name: String, path: String, icon: String? = nil) {
        self.name = name; self.path = path; self.icon = icon
    }
}

/// Enumerate installed `.app` bundles in the standard locations (Foundation
/// only — launching them is the app's job, via a `launch` control event).
public enum InstalledApps {
    public static func list() -> [CompanionAppDTO] {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities",
                    "/System/Applications", "/System/Applications/Utilities",
                    (fm.homeDirectoryForCurrentUser.path + "/Applications")]
        var seen = Set<String>()
        var apps: [CompanionAppDTO] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                guard seen.insert(name).inserted else { continue }
                apps.append(CompanionAppDTO(name: name, path: "\(dir)/\(item)"))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - CompactOS (single-window streaming)

/// `GET /windows` response — the Mac's open windows, for the CompactOS picker.
public struct CompanionWindowsDTO: Codable, Sendable {
    public var windows: [CompanionWindowDTO]
    public init(windows: [CompanionWindowDTO]) { self.windows = windows }
}

/// One open Mac window.
public struct CompanionWindowDTO: Codable, Sendable {
    public var id: UInt32            // CGWindowID
    public var app: String           // owning app's name
    public var appPath: String?      // owning app's bundle path (icon lookup)
    public var title: String?
    public var width: Int            // points
    public var height: Int
    public var isOnScreen: Bool      // false = minimized or on another Space
    public init(id: UInt32, app: String, appPath: String?, title: String?,
                width: Int, height: Int, isOnScreen: Bool) {
        self.id = id; self.app = app; self.appPath = appPath; self.title = title
        self.width = width; self.height = height; self.isOnScreen = isOnScreen
    }
}

/// `POST /compact/open` request — launch/focus an app (or a specific window)
/// and fit its window to the device's screen so the stream maps ~1:1.
public struct CompanionCompactOpenRequestDTO: Codable, Sendable {
    public var appPath: String?      // open/focus this app (its frontmost window)…
    public var windowId: UInt32?     // …or target a specific window
    public var width: Int            // requested window size (points)
    public var height: Int
    public init(appPath: String?, windowId: UInt32?, width: Int, height: Int) {
        self.appPath = appPath; self.windowId = windowId
        self.width = width; self.height = height
    }
}

/// `POST /compact/open` response — the window the device should stream.
public struct CompanionCompactOpenResponseDTO: Codable, Sendable {
    public var windowId: UInt32
    public var width: Int            // actual size after the app's min-size clamp
    public var height: Int
    public init(windowId: UInt32, width: Int, height: Int) {
        self.windowId = windowId; self.width = width; self.height = height
    }
}

/// `GET /power` — the Mac's reachability + wake/unlock state, so the device
/// can wake it (Wake-on-LAN) and offer unlock.
/// A custom (user-added) OpenAI-compatible provider, as advertised to devices.
/// No key — the Mac holds it and runs the call.
public struct CompanionAIProviderDTO: Codable, Sendable {
    public var id: String
    public var name: String
    public var models: [String]
    public init(id: String, name: String, models: [String]) {
        self.id = id; self.name = name; self.models = models
    }
}

public struct CompanionAIProvidersDTO: Codable, Sendable {
    public var providers: [CompanionAIProviderDTO]
    public init(providers: [CompanionAIProviderDTO]) { self.providers = providers }
}

/// One output device the Mac could play through (`GET /audio/outputs`).
public struct CompanionAudioOutputDTO: Codable, Sendable {
    public var uid: String        // stable CoreAudio device UID
    public var name: String       // "MacBook Pro Speakers", "AirPods Pro"
    public var current: Bool      // the default output right now

    public init(uid: String, name: String, current: Bool) {
        self.uid = uid
        self.name = name
        self.current = current
    }
}

public struct CompanionAudioOutputsDTO: Codable, Sendable {
    public var outputs: [CompanionAudioOutputDTO]
    public init(outputs: [CompanionAudioOutputDTO]) { self.outputs = outputs }
}

/// `POST /audio/output` — make this device the default output.
public struct CompanionAudioOutputSetDTO: Codable, Sendable {
    public var uid: String
    public init(uid: String) { self.uid = uid }
}

/// The Mac's own weather report (`GET /system`): what the vitals tiles on a
/// device show. Everything here is cheap to read — the endpoint is polled.
public struct CompanionSystemDTO: Codable, Sendable {
    /// Whole-machine CPU load, 0…1, averaged since the previous ask (the first
    /// ask answers with the average since boot, which settles by the second).
    public var cpu: Double
    /// Memory in use the way Activity Monitor counts it (app + wired +
    /// compressed), and the machine's total, in bytes.
    public var memUsed: Int64
    public var memTotal: Int64
    /// The boot volume's free space as purgeable-aware "available for use".
    public var diskFree: Int64
    public var diskTotal: Int64
    /// 0…1, nil on a desktop with no battery.
    public var battery: Double?
    public var charging: Bool?
    public var onAC: Bool
    /// ProcessInfo's thermal state: nominal | fair | serious | critical.
    public var thermal: String
    /// Seconds since boot.
    public var uptime: Double
    /// Built-in display brightness, 0…1. Nil when there is no built-in display
    /// to ask (a desktop, lid-only externals) — the remote slider then falls
    /// back to stepping the brightness keys.
    public var brightness: Double?

    public init(cpu: Double, memUsed: Int64, memTotal: Int64,
                diskFree: Int64, diskTotal: Int64,
                battery: Double?, charging: Bool?, onAC: Bool,
                thermal: String, uptime: Double, brightness: Double? = nil) {
        self.cpu = cpu
        self.memUsed = memUsed
        self.memTotal = memTotal
        self.diskFree = diskFree
        self.diskTotal = diskTotal
        self.battery = battery
        self.charging = charging
        self.onAC = onAC
        self.thermal = thermal
        self.uptime = uptime
        self.brightness = brightness
    }
}

public struct CompanionPowerDTO: Codable, Sendable {
    public var locked: Bool            // login/lock window is up
    public var displayAsleep: Bool     // the display has slept
    public var keepAwake: Bool         // a keep-awake assertion is held
    public var canWake: Bool           // remote wake is allowed
    public var canUnlock: Bool         // remote unlock is allowed (password stored)
    public var mac: String?            // primary NIC MAC, for Wake-on-LAN
    public var broadcast: String?      // subnet broadcast address, for WoL
    public var privacyUp: Bool         // the privacy curtain is currently raised
    public var onACPower: Bool         // running on AC power (lid-closed capture needs it)
    /// macOS grants these to a signed binary and takes them away again when the
    /// binary changes: rebuild the app and both are gone until someone re-ticks
    /// them. Without Accessibility the Mac cannot type its own password, and
    /// without Screen Recording the capture yields nothing, while every other
    /// route keeps working perfectly. Reported so a device can name the missing
    /// one instead of showing a dead unlock button over a black screen.
    public var accessibility: Bool?
    public var screenRecording: Bool?
    /// This Mac's own key-repeat settings, so a device holding a key can repeat
    /// at the rate the person actually chose in System Settings.
    public var keyRepeatDelay: Double?
    public var keyRepeatInterval: Double?
    public init(locked: Bool, displayAsleep: Bool, keepAwake: Bool,
                canWake: Bool, canUnlock: Bool, mac: String?, broadcast: String?,
                privacyUp: Bool = false, onACPower: Bool = true,
                accessibility: Bool? = nil, screenRecording: Bool? = nil,
                keyRepeatDelay: Double? = nil, keyRepeatInterval: Double? = nil) {
        self.locked = locked; self.displayAsleep = displayAsleep; self.keepAwake = keepAwake
        self.canWake = canWake; self.canUnlock = canUnlock
        self.mac = mac; self.broadcast = broadcast
        self.privacyUp = privacyUp
        self.onACPower = onACPower
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.keyRepeatDelay = keyRepeatDelay
        self.keyRepeatInterval = keyRepeatInterval
    }
}

// MARK: - Universal clipboard (copy here, paste there)

/// One representation of the clipboard content — the same item usually ships
/// several (an image as PNG plus its file name, rich text plus plain text), so
/// the receiving side can offer the richest form each paste target accepts.
public struct CompanionClipboardRepDTO: Codable, Sendable {
    public var type: String          // UTI, e.g. "public.utf8-plain-text", "public.png"
    public var name: String?         // filename, when the data is a file's contents
    public var data: Data            // raw bytes (base64 over the wire)
    public init(type: String, name: String? = nil, data: Data) {
        self.type = type; self.name = name; self.data = data
    }
}

/// The clipboard item riding `GET`/`POST /clipboard`. `seq` is the Mac's
/// ordering: time-based so it stays monotonic across Mac app restarts, and a
/// device only applies an item whose seq is beyond what it has already seen.
/// A GET reply with empty `reps` means "nothing newer than what you asked for".
public struct CompanionClipboardDTO: Codable, Sendable {
    public var seq: Int
    public var origin: String        // "mac" | the pushing device's name
    public var at: Date?
    public var reps: [CompanionClipboardRepDTO]
    public init(seq: Int, origin: String, at: Date? = nil, reps: [CompanionClipboardRepDTO]) {
        self.seq = seq; self.origin = origin; self.at = at; self.reps = reps
    }
}

/// `POST /clipboard` reply — the seq the push landed as, so the sender skips
/// re-fetching its own item.
public struct CompanionClipboardAckDTO: Codable, Sendable {
    public var seq: Int
    public init(seq: Int) { self.seq = seq }
}

// MARK: - Code (native file editing)

/// One entry in a directory listing (`GET /code/list`).
public struct CompanionCodeEntryDTO: Codable, Sendable {
    public var name: String
    public var path: String
    public var dir: Bool
    public var size: Int64
    public init(name: String, path: String, dir: Bool, size: Int64) {
        self.name = name; self.path = path; self.dir = dir; self.size = size
    }
}

/// A directory listing, folders first (`GET /code/list?path=`).
public struct CompanionCodeListDTO: Codable, Sendable {
    public var path: String
    public var entries: [CompanionCodeEntryDTO]
    public init(path: String, entries: [CompanionCodeEntryDTO]) {
        self.path = path; self.entries = entries
    }
}

/// A text file's content (`GET /code/file?path=`, and the `PUT` body).
public struct CompanionCodeFileDTO: Codable, Sendable {
    public var path: String
    public var content: String
    public init(path: String, content: String) {
        self.path = path; self.content = content
    }
}

/// `POST /code/open` body — hand a path to the Mac's editor.
public struct CompanionCodeOpenDTO: Codable, Sendable {
    public var path: String
    public init(path: String) { self.path = path }
}

/// A plain list of names (repos, branches) for the app's pickers.
public struct CompanionListDTO: Codable, Sendable {
    public var values: [String]
    public init(values: [String]) { self.values = values }
}

/// `POST /pair` request / response.
public struct CompanionPairRequestDTO: Codable, Sendable {
    public var code: String
    public var deviceName: String
}

public struct CompanionPairResponseDTO: Codable, Sendable {
    public var token: String
    public var runnerName: String
    /// Base64 SHA-256 of the certificate the Mac presents on the LAN, stamped in
    /// by the server. A device keeps it and accepts nothing else there. Nil when
    /// the Mac has no LAN listener, and absent entirely from an older Mac, so a
    /// device treats nil as "no direct LAN connection available".
    public var lanCertSha256: String? = nil
}

/// How to reach this Mac directly over the LAN. Fetched over the tunnel, whose
/// certificate the device has already checked against the public CA set, so the
/// pin arrives on a channel that is authenticated independently of the LAN it
/// describes. This is what lets a device paired before LAN TLS existed pick the
/// pin up on its own instead of being re-paired by hand.
public struct CompanionLANDTO: Codable, Sendable {
    public var port: Int
    public var certSha256: String?
}

/// Shared JSON coding — snake_case keys, ISO-8601 dates, matching the app.
public enum CompanionJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Map an internal run result to the app's status vocabulary.
    public static func status(_ result: RunResult) -> String {
        switch result {
        case .succeeded: return "passed"
        case .failed:    return "failed"
        case .cancelled: return "cancelled"
        }
    }

    /// Heuristic log level so failures show red in the app's console.
    public static func level(for text: String) -> String {
        let l = text.lowercased()
        if text.contains("❌") || l.contains("error:") || l.contains("** build failed")
            || l.contains("** test failed") || l.contains("fatal error:") { return "error" }
        return "info"
    }
}
