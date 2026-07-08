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
