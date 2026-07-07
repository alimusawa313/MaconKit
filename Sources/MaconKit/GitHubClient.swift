//
//  GitHubClient.swift
//  MaconKit
//
//  GitHub REST implementation of GitProvider. Authenticates with a Personal
//  Access Token (classic or fine-grained) that has `repo` (contents + statuses)
//  access to the repositories you build.
//

import Foundation

public struct GitHubClient: Sendable, GitProvider {
    public init(token: String) { self.token = token }
    let token: String

    public var kind: GitProviderKind { .github }

    private static let api = "https://api.github.com"

    enum ClientError: LocalizedError {
        case http(Int, String)
        case badResponse
        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "HTTP \(code): \(body)"
            case .badResponse: return "Unexpected response"
            }
        }
    }

    // MARK: - Requests

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: path.hasPrefix("http") ? path : "\(Self.api)\(path)") else {
            throw ClientError.badResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))",
                     forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("macon", forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func getArray(_ path: String) async throws -> [[String: Any]] {
        let data = try await request(path)
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    private func getObject(_ path: String) async throws -> [String: Any] {
        let data = try await request(path)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.badResponse
        }
        return obj
    }

    // MARK: - GitProvider

    public func latestCommit(workspace: String, repo: String, branch: String) async throws -> String {
        // /commits/{ref} resolves a branch name to its head commit object.
        let obj = try await getObject("/repos/\(workspace)/\(repo)/commits/\(branch)")
        guard let sha = obj["sha"] as? String else { throw ClientError.badResponse }
        return sha
    }

    public func listRepositories(workspace: String) async throws -> [String] {
        // The token's accessible repos (incl. private + org), filtered to this owner.
        let repos = try await getArray("/user/repos?per_page=100&sort=updated&affiliation=owner,collaborator,organization_member")
        let owner = workspace.lowercased()
        let names = repos.compactMap { r -> String? in
            let full = (r["full_name"] as? String) ?? ""
            let parts = full.split(separator: "/", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == owner else { return nil }
            return String(parts[1])
        }
        // Fall back to public repos of a user/org if the token sees none under this owner.
        if names.isEmpty {
            return try await getArray("/users/\(workspace)/repos?per_page=100&sort=updated")
                .compactMap { $0["name"] as? String }
        }
        return names
    }

    public func listBranches(workspace: String, repo: String) async throws -> [String] {
        try await getArray("/repos/\(workspace)/\(repo)/branches?per_page=100")
            .compactMap { $0["name"] as? String }
    }

    public func listOpenPullRequests(workspace: String, repo: String) async throws -> [GitPullRequest] {
        try await getArray("/repos/\(workspace)/\(repo)/pulls?state=open&per_page=50").compactMap { pr in
            guard let number = pr["number"] as? Int,
                  let head = pr["head"] as? [String: Any],
                  let sha = head["sha"] as? String,
                  let srcRef = head["ref"] as? String else { return nil }
            let baseRef = (pr["base"] as? [String: Any])?["ref"] as? String ?? ""
            return GitPullRequest(
                id: number,
                title: pr["title"] as? String ?? "PR #\(number)",
                sourceBranch: srcRef,
                sourceCommit: sha,
                destBranch: baseRef)
        }
    }

    public func postBuildStatus(workspace: String, repo: String, sha: String,
                                key: String, state: BuildStatus, name: String,
                                description: String) async throws {
        let raw: String
        switch state {
        case .inProgress: raw = "pending"
        case .successful: raw = "success"
        case .failed:     raw = "failure"
        }
        // Commit Statuses API. `context` is the check name shown on the PR.
        _ = try await request("/repos/\(workspace)/\(repo)/statuses/\(sha)", method: "POST", body: [
            "state": raw,
            "context": name.isEmpty ? key : name,
            "description": String(description.prefix(140)),   // GitHub caps at 140 chars
            "target_url": "https://github.com/\(workspace)/\(repo)/commit/\(sha)",
        ])
    }

    // MARK: - Clone + env

    public func cloneURL(workspace: String, repo: String) -> (authed: String, safe: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let authed = "https://x-access-token:\(t)@github.com/\(workspace)/\(repo).git"
        let safe = "https://x-access-token:***@github.com/\(workspace)/\(repo).git"
        return (authed, safe)
    }

    public func stepEnv(workspace: String, repo: String, sha: String, branch: String,
                        pr: GitPullRequest?, buildNumber: Int) -> [String: String] {
        var env = [
            "GITHUB_TOKEN": token,
            "DANGER_GITHUB_API_TOKEN": token,   // so Danger can post on PRs
            "GITHUB_REPOSITORY": "\(workspace)/\(repo)",
            "GITHUB_SHA": sha,
            "GITHUB_REF_NAME": branch,
            "GITHUB_RUN_NUMBER": "\(buildNumber)",
        ]
        if let pr {
            env["GITHUB_PR_NUMBER"] = "\(pr.id)"
            env["GITHUB_HEAD_REF"] = pr.sourceBranch
            env["GITHUB_BASE_REF"] = pr.destBranch
        }
        return env
    }
}
