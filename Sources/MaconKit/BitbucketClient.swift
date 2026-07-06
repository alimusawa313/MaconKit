//
//  BitbucketClient.swift
//  MacON
//
//  Thin Bitbucket Cloud REST client: read latest commit, post build status.
//

import Foundation

public struct BitbucketClient: Sendable {
    public init(email: String, token: String) { self.email = email; self.token = token }
    let email: String
    let token: String

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

    private var authHeader: String {
        // Trim: a trailing newline/space from pasting silently breaks Basic auth.
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Basic " + Data("\(e):\(t)".utf8).base64EncodedString()
    }

    private static let base = "https://api.bitbucket.org/2.0/repositories"

    /// The head commit hash of a branch.
    func latestCommit(workspace: String, repo: String, branch: String) async throws -> String {
        let path = "\(Self.base)/\(workspace)/\(repo)/refs/branches/\(branch)"
        guard let url = URL(string: path) else { throw ClientError.badResponse }
        var req = URLRequest(url: url)
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let target = json["target"] as? [String: Any],
              let hash = target["hash"] as? String else { throw ClientError.badResponse }
        return hash
    }

    // MARK: - Listing (for dropdowns)

    /// Workspaces the account belongs to (slugs).
    public func listWorkspaces() async throws -> [String] {
        try await pagedValues("https://api.bitbucket.org/2.0/workspaces?pagelen=100")
            .compactMap { $0["slug"] as? String }
    }

    /// Repositories in a workspace (slugs), most-recently-updated first.
    public func listRepositories(workspace: String) async throws -> [String] {
        try await pagedValues("\(Self.base)/\(workspace)?pagelen=100&sort=-updated_on")
            .compactMap { $0["slug"] as? String }
    }

    /// Branch names in a repository.
    public func listBranches(workspace: String, repo: String) async throws -> [String] {
        try await pagedValues("\(Self.base)/\(workspace)/\(repo)/refs/branches?pagelen=100")
            .compactMap { $0["name"] as? String }
    }

    struct PullRequest: Sendable, Identifiable {
        let id: Int
        let title: String
        let sourceBranch: String
        let sourceCommit: String
        let destBranch: String
    }

    /// Open pull requests, optionally filtered by destination branch.
    func listOpenPullRequests(workspace: String, repo: String) async throws -> [PullRequest] {
        let base = "\(Self.base)/\(workspace)/\(repo)/pullrequests?state=OPEN&pagelen=50"
        return try await pagedValues(base).compactMap { pr in
            guard let id = pr["id"] as? Int,
                  let source = pr["source"] as? [String: Any],
                  let srcBranch = (source["branch"] as? [String: Any])?["name"] as? String,
                  let srcCommit = (source["commit"] as? [String: Any])?["hash"] as? String
            else { return nil }
            let dest = (pr["destination"] as? [String: Any])?["branch"] as? [String: Any]
            return PullRequest(
                id: id,
                title: pr["title"] as? String ?? "PR #\(id)",
                sourceBranch: srcBranch,
                sourceCommit: srcCommit,
                destBranch: dest?["name"] as? String ?? "")
        }
    }

    /// GET a paginated collection, following `next` up to `maxPages`.
    private func pagedValues(_ start: String, maxPages: Int = 5) async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        var next: String? = start
        var pages = 0
        while let u = next, pages < maxPages, let url = URL(string: u) {
            pages += 1
            var req = URLRequest(url: url)
            req.setValue(authHeader, forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw ClientError.badResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            if let values = json["values"] as? [[String: Any]] { results.append(contentsOf: values) }
            next = json["next"] as? String
        }
        return results
    }

    enum Status: String { case inProgress = "INPROGRESS", successful = "SUCCESSFUL", failed = "FAILED" }

    /// Post a build status to a commit (shows up as a CI check on PRs).
    func postBuildStatus(workspace: String, repo: String, sha: String,
                         key: String, state: Status, name: String,
                         description: String) async throws {
        let path = "\(Self.base)/\(workspace)/\(repo)/commit/\(sha)/statuses/build"
        guard let url = URL(string: path) else { throw ClientError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "key": key,
            "state": state.rawValue,
            "name": name,
            "description": description,
            "url": "https://bitbucket.org/\(workspace)/\(repo)/commits/\(sha)",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
