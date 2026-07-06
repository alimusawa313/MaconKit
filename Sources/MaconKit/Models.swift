//
//  Models.swift
//  MacON
//
//  Value types for the runner pool.
//

import Foundation

/// One Bitbucket self-hosted runner registered on this Mac. A pool holds many —
/// typically one per repository/workspace, each with its own credentials
/// (baked into `startCommand`) and its own checkout directory.
public struct RunnerInstance: Identifiable, Codable, Equatable {
    public var id: UUID = UUID()
    public var name: String = "New Runner"
    /// The full command Bitbucket generates in Repo → Settings → Runners.
    public var startCommand: String = ""
    /// Where this runner checks out repos. Give each runner its OWN dir so their
    /// working files never collide.
    public var workingDirectory: String = ""
    /// Relaunch automatically if the agent exits unexpectedly.
    public var restartOnCrash: Bool = true
}

/// Cleanup preferences, shared by the whole pool.
///
/// Split deliberately: `emptyWorkingDirOnStop` is *per-runner* and only touches
/// that runner's own directory, so it's safe to run while other runners work.
/// The cache flags target shared `~/Library` locations, so the pool only applies
/// them when every runner is stopped.
public struct CleanupSettings: Codable, Equatable {
    // Per-runner, on stop (isolated → always safe):
    public var emptyWorkingDirOnStop = true

    // Global cache cleanup (shared paths → only when all runners are stopped):
    public var derivedData = true
    public var swiftPMCache = true
    public var archives = false
    public var pruneSimulators = false

    /// Plan that cleans only one runner's working directory.
    public func workingDirPlan(for dir: String) -> CleanupPlan {
        CleanupPlan(derivedData: false, archives: false, swiftPMCache: false,
                    workingDirectory: dir, pruneSimulators: false)
    }

    /// Plan for the shared machine caches.
    public var cachePlan: CleanupPlan {
        CleanupPlan(derivedData: derivedData, archives: archives,
                    swiftPMCache: swiftPMCache, workingDirectory: nil,
                    pruneSimulators: pruneSimulators)
    }
}
