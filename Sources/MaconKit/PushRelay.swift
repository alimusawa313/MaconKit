//
//  PushRelay.swift
//  MaconKit
//
//  Pushes to Macon+ go through the relay at macon-push.maconid.workers.dev.
//  APNs token auth only accepts a JWT signed by the team that owns the app in
//  `apns-topic`, and that team is the one that ships the companion; so no key
//  a user could import would ever push to it. The relay holds the one key that
//  can, and this Mac hands it "push this to that device".
//
//  "That device" is a *handle*: the companion registers its APNs token with
//  the relay and passes this Mac the sealed result. The Mac never sees a raw
//  token, and the relay stores nothing. Apple's status and reason come back
//  unchanged, so 410 Unregistered still means "drop this device".
//

import Foundation

public actor PushRelay {

    /// Where the relay lives. `MACON_PUSH_RELAY` in the environment overrides
    /// it, for pointing a debug build at a test deployment.
    public static let defaultURL = URL(string: "https://macon-push.maconid.workers.dev")!

    /// A registered device as the companion reports it. Raw APNs tokens (from
    /// a companion older than the relay) are not handles and are never sent.
    public static func isHandle(_ value: String) -> Bool { value.hasPrefix("h1.") }

    private let base: URL
    private let session: URLSession

    public init(base: URL? = nil) {
        if let base {
            self.base = base
        } else if let env = ProcessInfo.processInfo.environment["MACON_PUSH_RELAY"],
                  let url = URL(string: env) {
            self.base = url
        } else {
            self.base = Self.defaultURL
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    /// An alert with the app's standard shape: title and body, a sound, an
    /// optional category (the action buttons the app registered) and thread
    /// id (groups the pushes about one thing), plus flat custom keys.
    /// Returns nil on success, else a short human error containing Apple's
    /// status where there is one ("APNs 410: Unregistered").
    @discardableResult
    public func sendAlert(handle: String, title: String, body: String,
                          payload: [String: String],
                          category: String? = nil, threadID: String? = nil) async -> String? {
        var root: [String: Any] = payload
        var aps: [String: Any] = ["alert": ["title": title, "body": body], "sound": "default"]
        if let category { aps["category"] = category }
        if let threadID { aps["thread-id"] = threadID }
        root["aps"] = aps
        return await post(handle: handle, pushType: "alert", payload: root, priority: 10)
    }

    /// A Live Activity push. `payload` is the whole body, already serialised:
    /// `{"aps": {"event": "start" | "update" | "end", "content-state": …}}`,
    /// with `attributes-type` and `attributes` on a start. The handle wraps a
    /// push-to-start token for a start and the card's own token otherwise.
    @discardableResult
    public func sendLiveActivity(handle: String, payload: Data) async -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) else {
            return "Bad payload"
        }
        return await post(handle: handle, pushType: "liveactivity", payload: object, priority: 10)
    }

    private func post(handle: String, pushType: String, payload: Any, priority: Int) async -> String? {
        guard Self.isHandle(handle) else { return "Not a relay handle" }
        let body: [String: Any] = [
            "handle": handle, "pushType": pushType, "payload": payload, "priority": priority,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return "Bad payload" }
        var req = URLRequest(url: base.appendingPathComponent("v1/push"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data
        do {
            let (respData, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return "No response" }
            if http.statusCode == 200 { return nil }
            // The relay answers {"status": <Apple's>, "reason": <Apple's>} when
            // Apple answered, or {"error": ...} when the request never got there.
            let json = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any]
            if let status = json?["status"] as? Int, status != 0 {
                return "APNs \(status): \(json?["reason"] as? String ?? "")"
            }
            let detail = (json?["reason"] as? String) ?? (json?["error"] as? String) ?? ""
            return "Relay \(http.statusCode): \(detail)"
        } catch {
            return error.localizedDescription
        }
    }
}
