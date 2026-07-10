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
    public init(pipelines: [CompanionPipelineDTO]) { self.pipelines = pipelines }
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
