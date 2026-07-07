//
//  GitProvider.swift
//  MaconKit
//
//  A provider-agnostic interface over a git host (Bitbucket, GitHub). Everything
//  the pipeline engine needs — read head commits, list repos/branches/PRs, clone
//  with auth, post build status, and expose provider-native env vars — goes
//  through this so a pipeline can point at either host.
//

import Foundation

/// Which git host a pipeline talks to.
public enum GitProviderKind: String, Codable, CaseIterable, Sendable {
    case bitbucket, github

    public var label: String { self == .bitbucket ? "Bitbucket" : "GitHub" }

    /// What the "workspace" field means to a user of this provider.
    public var ownerLabel: String { self == .bitbucket ? "Workspace" : "Owner / org" }
    public var ownerPlaceholder: String { self == .bitbucket ? "workspace-slug" : "owner or org" }

    /// Whether this provider authenticates with an email (Bitbucket) or a bare token (GitHub).
    public var usesEmail: Bool { self == .bitbucket }
}

/// A pull request, normalized across providers.
public struct GitPullRequest: Sendable, Identifiable {
    public let id: Int
    public let title: String
    public let sourceBranch: String
    public let sourceCommit: String
    public let destBranch: String
    public init(id: Int, title: String, sourceBranch: String,
                sourceCommit: String, destBranch: String) {
        self.id = id; self.title = title; self.sourceBranch = sourceBranch
        self.sourceCommit = sourceCommit; self.destBranch = destBranch
    }
}

/// A commit build state, mapped to each provider's own vocabulary.
public enum BuildStatus: Sendable { case inProgress, successful, failed }

/// The operations the pipeline engine performs against a git host.
public protocol GitProvider: Sendable {
    var kind: GitProviderKind { get }

    /// Head commit sha of a branch.
    func latestCommit(workspace: String, repo: String, branch: String) async throws -> String
    /// Repo names accessible under an owner/workspace (for the UI dropdown).
    func listRepositories(workspace: String) async throws -> [String]
    /// Branch names in a repo (for the UI dropdown).
    func listBranches(workspace: String, repo: String) async throws -> [String]
    /// Open pull requests.
    func listOpenPullRequests(workspace: String, repo: String) async throws -> [GitPullRequest]
    /// Report a build's state on a commit (shows as a CI check on PRs).
    func postBuildStatus(workspace: String, repo: String, sha: String,
                         key: String, state: BuildStatus, name: String,
                         description: String) async throws

    /// `git clone` URL with the token embedded, plus a masked copy safe to log.
    func cloneURL(workspace: String, repo: String) -> (authed: String, safe: String)
    /// Provider-native env vars exposed to every step (for Danger, fastlane, etc.).
    func stepEnv(workspace: String, repo: String, sha: String, branch: String,
                 pr: GitPullRequest?, buildNumber: Int) -> [String: String]
}
