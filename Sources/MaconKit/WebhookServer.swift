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
    private let queue = DispatchQueue(label: "macon.webhook")
    private var listener: NWListener?

    private let onEvent: @Sendable (WebhookEvent) -> Void
    private let onLog: @Sendable (String) -> Void

    public init(port: UInt16,
                onLog: @escaping @Sendable (String) -> Void,
                onEvent: @escaping @Sendable (WebhookEvent) -> Void) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 8787
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

            let method = header.split(separator: "\r\n").first?.split(separator: " ").first.map(String.init) ?? ""
            if method.uppercased() == "POST" {
                let body = acc.subdata(in: bodyStart..<acc.endIndex)
                let eventKey = self.headerValue(header, "x-event-key")
                if let event = Self.parse(body: body, eventKey: eventKey) {
                    self.onEvent(event)
                }
            }
            self.respond(conn, method: method)
        }
    }

    private func respond(_ conn: NWConnection, method: String) {
        let body = method.uppercased() == "GET" ? "macon webhook ok\n" : "received\n"
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
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

    /// Turn a Bitbucket webhook JSON body into a `WebhookEvent`. Handles the two
    /// event families we build on: `repo:push` and `pullrequest:*`.
    static func parse(body: Data, eventKey: String?) -> WebhookEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let repo = ((obj["repository"] as? [String: Any])?["full_name"] as? String) ?? ""
        let key = eventKey ?? ""

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
}
