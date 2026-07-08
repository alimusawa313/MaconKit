//
//  WebhookServer.swift
//  MaconKit
//
//  A tiny HTTP listener (Network.framework, no dependencies) that receives
//  Bitbucket webhook POSTs and turns them into build triggers. This is the
//  push-based alternative to polling: Bitbucket calls us the instant a commit
//  lands, so there's no 30s lag and no idle API traffic.
//

import Foundation
import Network
import CryptoKit

/// A parsed Bitbucket webhook event (push or pull request).
public struct WebhookEvent: Sendable {
    public enum Kind: Sendable { case push, pullRequest, other }
    public var kind: Kind
    public var repoFullName: String        // "workspace/repo"
    public var branch: String              // pushed branch, or PR source branch
    public var commit: String              // new head sha
    public var prID: Int?
    public var prTitle: String?
    public var prSourceBranch: String?
    public var prDestBranch: String?
}

/// Minimal HTTP/1.1 server for a single webhook endpoint. Thread-safe enough for
/// our use: lifecycle (start/stop) and connection handling run on a private queue.
public final class WebhookServer: @unchecked Sendable {

    private let port: NWEndpoint.Port
    private let secret: String
    private let queue = DispatchQueue(label: "macon.webhook")
    private var listener: NWListener?

    private let onEvent: @Sendable (WebhookEvent) -> Void
    private let onLog: @Sendable (String) -> Void

    public init(port: UInt16,
                secret: String = "",
                onLog: @escaping @Sendable (String) -> Void,
                onEvent: @escaping @Sendable (WebhookEvent) -> Void) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 8787
        self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.onLog = onLog
        self.onEvent = onEvent
    }

    // MARK: - Lifecycle

    public func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            do {
                let l = try NWListener(using: params, on: port)
                l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                l.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .failed(let e): self?.onLog("✗ Webhook server failed: \(e.localizedDescription)")
                    case .cancelled:     break
                    default:             break
                    }
                }
                l.start(queue: queue)
                listener = l
            } catch {
                onLog("✗ Couldn't bind port \(port.rawValue): \(error.localizedDescription)")
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var acc = buffer
            if let data, !data.isEmpty { acc.append(data) }

            // Wait until we have the full header block.
            guard let sep = acc.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil { conn.cancel() } else { self.receive(conn, buffer: acc) }
                return
            }
            let headerData = acc.subdata(in: acc.startIndex..<sep.lowerBound)
            let header = String(data: headerData, encoding: .utf8) ?? ""
            let bodyStart = sep.upperBound
            let contentLength = self.headerInt(header, "content-length") ?? 0

            // Read the rest of the body if we don't have all of it yet.
            let have = acc.distance(from: bodyStart, to: acc.endIndex)
            if have < contentLength && !isComplete && error == nil {
                self.receive(conn, buffer: acc)
                return
            }

            let requestLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = requestLine.split(separator: " ")
            let method = parts.first.map(String.init) ?? ""
            let path = parts.count > 1 ? String(parts[1]) : "/"

            if method.uppercased() == "POST" {
                let body = acc.subdata(in: bodyStart..<acc.endIndex)
                let ghSig = self.headerValue(header, "x-hub-signature-256")
                if !self.authorized(body: body, path: path, githubSignature: ghSig) {
                    self.onLog("⛔︎ Rejected webhook — secret/signature mismatch.")
                    self.respond(conn, status: "401 Unauthorized", body: "unauthorized\n")
                    return
                }
                let bbEvent = self.headerValue(header, "x-event-key")       // Bitbucket
                let ghEvent = self.headerValue(header, "x-github-event")    // GitHub
                if let event = Self.parse(body: body, bitbucketEvent: bbEvent, githubEvent: ghEvent) {
                    self.onEvent(event)
                }
            }
            self.respond(conn, status: "200 OK", body: method.uppercased() == "GET" ? "macon webhook ok\n" : "received\n")
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/plain\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Decide whether a request may trigger a build.
    /// - No secret configured → allow (safe behind a private tunnel/LAN).
    /// - GitHub sends X-Hub-Signature-256 → verify the HMAC-SHA256 of the body.
    /// - Otherwise (Bitbucket/generic) → require the secret to appear in the URL path.
    private func authorized(body: Data, path: String, githubSignature: String?) -> Bool {
        guard !secret.isEmpty else { return true }
        if let sig = githubSignature {
            let key = SymmetricKey(data: Data(secret.utf8))
            let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
            let expected = "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
            return constantTimeEqual(sig, expected)
        }
        return path.contains(secret)
    }

    /// Length-aware, non-short-circuiting compare (avoids leaking match length via timing).
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: - Header helpers

    private func headerValue(_ header: String, _ name: String) -> String? {
        for line in header.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func headerInt(_ header: String, _ name: String) -> Int? {
        headerValue(header, name).flatMap { Int($0) }
    }

    // MARK: - Bitbucket payload parsing

    /// Turn a webhook JSON body into a `WebhookEvent`, autodetecting the provider
    /// from its header (`X-Event-Key` = Bitbucket, `X-GitHub-Event` = GitHub).
    static func parse(body: Data, bitbucketEvent: String?, githubEvent: String?) -> WebhookEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let gh = githubEvent { return parseGitHub(obj, event: gh) }
        return parseBitbucket(obj, key: bitbucketEvent ?? "")
    }

    private static func parseBitbucket(_ obj: [String: Any], key: String) -> WebhookEvent? {
        let repo = ((obj["repository"] as? [String: Any])?["full_name"] as? String) ?? ""

        // Pull request events.
        if key.hasPrefix("pullrequest"), let pr = obj["pullrequest"] as? [String: Any] {
            let source = pr["source"] as? [String: Any]
            let dest = pr["destination"] as? [String: Any]
            let sha = ((source?["commit"] as? [String: Any])?["hash"] as? String) ?? ""
            let src = ((source?["branch"] as? [String: Any])?["name"] as? String) ?? ""
            let dst = ((dest?["branch"] as? [String: Any])?["name"] as? String) ?? ""
            return WebhookEvent(kind: .pullRequest, repoFullName: repo, branch: src, commit: sha,
                                prID: pr["id"] as? Int, prTitle: pr["title"] as? String,
                                prSourceBranch: src, prDestBranch: dst)
        }

        // Push events: take the newest branch change with a target hash.
        if let push = obj["push"] as? [String: Any],
           let changes = push["changes"] as? [[String: Any]] {
            for change in changes {
                guard let new = change["new"] as? [String: Any],
                      (new["type"] as? String) == "branch",
                      let name = new["name"] as? String,
                      let sha = (new["target"] as? [String: Any])?["hash"] as? String
                else { continue }
                return WebhookEvent(kind: .push, repoFullName: repo, branch: name, commit: sha)
            }
        }
        return nil
    }

    private static func parseGitHub(_ obj: [String: Any], event: String) -> WebhookEvent? {
        let repo = ((obj["repository"] as? [String: Any])?["full_name"] as? String) ?? ""

        // Pull request events — only the actions that change code.
        if event == "pull_request", let pr = obj["pull_request"] as? [String: Any] {
            let action = obj["action"] as? String ?? ""
            guard ["opened", "reopened", "synchronize"].contains(action) else { return nil }
            let head = pr["head"] as? [String: Any]
            let base = pr["base"] as? [String: Any]
            let sha = (head?["sha"] as? String) ?? ""
            let src = (head?["ref"] as? String) ?? ""
            let dst = (base?["ref"] as? String) ?? ""
            return WebhookEvent(kind: .pullRequest, repoFullName: repo, branch: src, commit: sha,
                                prID: pr["number"] as? Int, prTitle: pr["title"] as? String,
                                prSourceBranch: src, prDestBranch: dst)
        }

        // Push events: ref = "refs/heads/<branch>", after = new head sha.
        if event == "push" {
            let ref = obj["ref"] as? String ?? ""
            let sha = obj["after"] as? String ?? ""
            let deleted = obj["deleted"] as? Bool ?? false
            let prefix = "refs/heads/"
            guard ref.hasPrefix(prefix), !deleted,
                  !sha.isEmpty, sha != String(repeating: "0", count: 40) else { return nil }
            return WebhookEvent(kind: .push, repoFullName: repo,
                                branch: String(ref.dropFirst(prefix.count)), commit: sha)
        }
        return nil
    }
}
