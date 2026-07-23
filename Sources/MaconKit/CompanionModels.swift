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
    public init(locked: Bool, displayAsleep: Bool, keepAwake: Bool,
                canWake: Bool, canUnlock: Bool, mac: String?, broadcast: String?,
                privacyUp: Bool = false, onACPower: Bool = true) {
        self.locked = locked; self.displayAsleep = displayAsleep; self.keepAwake = keepAwake
        self.canWake = canWake; self.canUnlock = canUnlock
        self.mac = mac; self.broadcast = broadcast
        self.privacyUp = privacyUp
        self.onACPower = onACPower
    }
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
