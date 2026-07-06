//
//  PipelineModels.swift
//  MacON
//
//  Value types for local CI pipelines (poll Bitbucket → build → report status).
//

import Foundation

public enum WatchMode: String, Codable, CaseIterable {
    case branch, pullRequests
    public var label: String { self == .branch ? "Branch" : "Pull Requests" }
}

/// A local CI pipeline: watch a branch (or open PRs) of a repo, build here.
public struct PipelineConfig: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var name = "New Pipeline"
    public var workspace = ""        // e.g. "academytools"
    public var repoSlug = ""         // e.g. "planpal-ios-learner-2"
    public var branch = "main"
    /// Watch a single branch, or all open pull requests.
    public var watchMode: WatchMode = .branch
    /// In PR mode, only build PRs targeting this branch (blank = all open PRs).
    public var prTargetBranch = ""
    /// Pipeline definition file to look for in the repo root. If found, its steps
    /// run instead of `buildCommand`.
    public var pipelineFile = "macon.yml"
    /// Which workflow to run from the pipeline file. Blank = auto (match branch /
    /// PR target against the file's `triggers`).
    public var workflow = ""
    /// Fallback when no pipeline file is present: the whole pipeline as one shell command.
    public var buildCommand = "bundle install && bundle exec fastlane test device:\"iPhone 17 Pro\""
    /// Where the repo is cloned/checked out for this pipeline.
    public var workingDirectory = ""
    public var pollSeconds = 30
    /// Post build status back to the commit on Bitbucket.
    public var postStatus = true
    /// Names of secret env vars (e.g. ASC_KEY_ID). Values live in the Keychain,
    /// never here. Injected into every step's environment.
    public var secretKeys: [String] = []

    public init() {}

    // Tolerant decoding: any missing key falls back to its default, so adding
    // new fields never invalidates previously-saved pipelines.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "New Pipeline"
        workspace = (try? c.decode(String.self, forKey: .workspace)) ?? ""
        repoSlug = (try? c.decode(String.self, forKey: .repoSlug)) ?? ""
        branch = (try? c.decode(String.self, forKey: .branch)) ?? "main"
        watchMode = (try? c.decode(WatchMode.self, forKey: .watchMode)) ?? .branch
        prTargetBranch = (try? c.decode(String.self, forKey: .prTargetBranch)) ?? ""
        pipelineFile = (try? c.decode(String.self, forKey: .pipelineFile)) ?? "macon.yml"
        workflow = (try? c.decode(String.self, forKey: .workflow)) ?? ""
        buildCommand = (try? c.decode(String.self, forKey: .buildCommand))
            ?? "bundle install && bundle exec fastlane test device:\"iPhone 17 Pro\""
        workingDirectory = (try? c.decode(String.self, forKey: .workingDirectory)) ?? ""
        pollSeconds = (try? c.decode(Int.self, forKey: .pollSeconds)) ?? 30
        postStatus = (try? c.decode(Bool.self, forKey: .postStatus)) ?? true
        secretKeys = (try? c.decode([String].self, forKey: .secretKeys)) ?? []
    }
}

/// Outcome of the most recent build.
public enum BuildState: Equatable {
    case idle
    case running(sha: String)
    case succeeded(sha: String)
    case failed(sha: String)

    public var shortSHA: String? {
        switch self {
        case .idle: return nil
        case .running(let s), .succeeded(let s), .failed(let s): return String(s.prefix(8))
        }
    }
    public var label: String {
        switch self {
        case .idle:            return "No builds yet"
        case .running(let s):  return "Building \(s.prefix(8))…"
        case .succeeded(let s):return "Passed \(s.prefix(8))"
        case .failed(let s):   return "Failed \(s.prefix(8))"
        }
    }
}

/// A repo-defined pipeline (macon.yml). Parsed from YAML→JSON at build time.
/// Supports Bitrise-style workflows, before/after composition, triggers, env,
/// and conditional / always-run steps.
public struct MaconPipeline: Codable {
    public var name: String?
    public var env: [String: String]?
    /// Simple single-workflow form: top-level steps (used when `workflows` is absent).
    public var steps: [MaconStep]?
    /// Named, composable workflows.
    public var workflows: [String: MaconWorkflow]?
    /// Branch/tag → workflow routing (like Bitrise trigger_map).
    public var triggers: [MaconTrigger]?

    public var hasContent: Bool {
        !(steps?.isEmpty ?? true) || !(workflows?.isEmpty ?? true)
    }
}

public struct MaconWorkflow: Codable {
    public var before_run: [String]?
    public var after_run: [String]?
    public var env: [String: String]?
    public var steps: [MaconStep]?
}

public struct MaconStep: Codable {
    public var name: String
    public var script: String
    /// Shell condition; the step runs only if this exits 0. Env vars are available.
    public var run_if: String?
    /// Run even if an earlier step already failed (like Bitrise is_always_run).
    public var always_run: Bool?
}

public struct MaconTrigger: Codable {
    public var branch: String?
    public var tag: String?
    public var pull_request: String?
    public var workflow: String
}

/// Final result of a saved run.
public enum RunResult: String, Codable {
    case succeeded, failed, cancelled
    public var icon: String {
        switch self {
        case .succeeded: return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }
    public var label: String {
        switch self {
        case .succeeded: return "Passed"
        case .failed:    return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Lightweight metadata for a past run (kept in the on-disk index).
public struct RunSummary: Identifiable, Codable, Equatable {
    public var id: UUID
    public var shaFull: String
    public var startedAt: Date
    public var finishedAt: Date
    public var result: RunResult

    public var shaShort: String { String(shaFull.prefix(8)) }
    public var duration: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }
    public var durationText: String {
        let s = Int(duration)
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }
}

/// A full saved run (metadata + its log), persisted to disk.
public struct PipelineRun: Codable {
    public var summary: RunSummary
    public var lines: [LogLine]
}

/// Bitbucket account used to poll, clone, and post status. Shared by all pipelines.
public struct BitbucketCredentials: Equatable {
    public var email: String = ""
    public var apiToken: String = ""
    public var isComplete: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        !apiToken.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
