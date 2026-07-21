//
//  APNsSender.swift
//  MaconKit
//
//  A tiny token-based (.p8) APNs provider. The Mac itself pushes to paired
//  devices — no middle server — so it signs an ES256 JWT with the user's
//  APNs auth key and POSTs to Apple over HTTP/2 (URLSession negotiates h2 for
//  https automatically). The provider token is cached and reused (Apple wants
//  it kept 20–60 min, not minted per push).
//

import Foundation
import CryptoKit

public actor APNsSender {

    public struct Config: Sendable, Equatable {
        public var keyP8: String     // PEM contents of the AuthKey_XXXX.p8
        public var keyID: String     // 10-char Key ID
        public var teamID: String    // 10-char Team ID
        public var topic: String     // the companion's bundle id
        public init(keyP8: String, keyID: String, teamID: String, topic: String) {
            self.keyP8 = keyP8; self.keyID = keyID; self.teamID = teamID; self.topic = topic
        }
        public var isComplete: Bool {
            !keyP8.isEmpty && keyID.count == 10 && teamID.count == 10 && !topic.isEmpty
        }
    }

    private var config: Config?
    private var cachedToken: (jwt: String, issued: Date)?

    public init() {}

    public func setConfig(_ config: Config?) {
        if config != self.config { cachedToken = nil }
        self.config = config
    }

    /// Push an alert to one device token. `sandbox` picks Apple's dev host —
    /// debug companion builds register a sandbox token, release a prod one.
    /// Returns nil on success, else a short human error (410 = unregister it).
    @discardableResult
    public func send(deviceToken: String, sandbox: Bool,
                     title: String, body: String,
                     payload: [String: String]) async -> String? {
        guard let config, config.isComplete else { return "APNs not configured" }
        let jwt: String
        do { jwt = try providerToken(config) }
        catch { return "Bad APNs key: \(error.localizedDescription)" }

        let host = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(deviceToken)") else {
            return "Bad device token"
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        req.setValue(config.topic, forHTTPHeaderField: "apns-topic")
        req.setValue("alert", forHTTPHeaderField: "apns-push-type")
        req.setValue("10", forHTTPHeaderField: "apns-priority")

        var root: [String: Any] = payload
        root["aps"] = ["alert": ["title": title, "body": body], "sound": "default"]
        guard let data = try? JSONSerialization.data(withJSONObject: root) else {
            return "Bad payload"
        }
        req.httpBody = data

        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return "No response" }
            if http.statusCode == 200 { return nil }
            let reason = String(data: respData, encoding: .utf8) ?? ""
            return "APNs \(http.statusCode): \(reason)"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: JWT (ES256)

    private func providerToken(_ config: Config) throws -> String {
        // Reuse for up to 50 min (Apple rejects tokens refreshed too often and
        // expires them past ~60 min).
        if let cached = cachedToken, Date().timeIntervalSince(cached.issued) < 50 * 60 {
            return cached.jwt
        }
        let key = try P256.Signing.PrivateKey(pemRepresentation: config.keyP8)

        // iat must be a JSON number, so both segments are built by hand.
        let iat = Int(Date().timeIntervalSince1970)
        let headerB64 = Self.b64url(Data("{\"alg\":\"ES256\",\"kid\":\"\(config.keyID)\"}".utf8))
        let claimsB64 = Self.b64url(Data("{\"iss\":\"\(config.teamID)\",\"iat\":\(iat)}".utf8))

        let signingInput = "\(headerB64).\(claimsB64)"
        let signature = try key.signature(for: Data(signingInput.utf8))
        let sigB64 = Self.b64url(signature.rawRepresentation)   // ES256 = raw r||s

        let jwt = "\(signingInput).\(sigB64)"
        cachedToken = (jwt, Date())
        return jwt
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
