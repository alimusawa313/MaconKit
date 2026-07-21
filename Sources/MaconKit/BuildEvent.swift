//
//  BuildEvent.swift
//  MaconKit
//
//  A pipeline lifecycle moment worth a push — build started, passed, failed,
//  cancelled. PipelineRunner emits these at its state transitions; the app
//  turns them into APNs alerts to paired devices.
//

import Foundation

public struct BuildEvent: Sendable {
    public enum Phase: String, Sendable {
        case started, passed, failed, cancelled
    }

    public var pipelineID: String     // config.id — the build id the companion opens
    public var pipelineName: String
    public var phase: Phase
    public var sha: String            // full commit sha
    public var branch: String
    public var detail: String?        // PR title, exit code, etc.

    public init(pipelineID: String, pipelineName: String, phase: Phase,
                sha: String, branch: String, detail: String? = nil) {
        self.pipelineID = pipelineID
        self.pipelineName = pipelineName
        self.phase = phase
        self.sha = sha
        self.branch = branch
        self.detail = detail
    }

    public var shaShort: String { String(sha.prefix(8)) }

    /// Notification title/body for this moment.
    public var alert: (title: String, body: String) {
        let where_ = branch.isEmpty ? shaShort : "\(branch) · \(shaShort)"
        switch phase {
        case .started:
            return ("▶️ \(pipelineName)", "Build started — \(where_)")
        case .passed:
            return ("✅ \(pipelineName)", "Build passed — \(where_)")
        case .failed:
            return ("❌ \(pipelineName)", "Build failed — \(detail ?? where_)")
        case .cancelled:
            return ("⏹ \(pipelineName)", "Build cancelled — \(where_)")
        }
    }
}
