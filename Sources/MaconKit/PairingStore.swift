//
//  PairingStore.swift
//  MaconKit
//
//  Device-code pairing for the companion app. A short-lived, single-use code is
//  exchanged for a long-lived device token; tokens persist to disk so they
//  survive restarts and can be listed/revoked from the CLI.
//
//  Security posture (the server may be exposed via a tunnel):
//    • codes are single-use and expire (default 15 min)
//    • tokens are 128-bit random, compared in constant time
//    • revocation is file-based, so it works even with no server running
//

import Foundation

public final class PairingStore: @unchecked Sendable {

    public struct Device: Codable, Sendable {
        public var token: String
        public var name: String
        public var pairedAt: Date
        public var tokenShort: String { String(token.prefix(8)) }
    }

    private let lock = NSLock()
    private var pending: (code: String, expires: Date)?
    private var devices: [Device]

    private let fileURL: URL

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacON/companion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("devices.json")
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([Device].self, from: data) {
            devices = list
        } else {
            devices = []
        }
    }

    public var deviceCount: Int { lock.withLock { devices.count } }
    public func deviceList() -> [Device] { lock.withLock { devices } }

    // MARK: Pairing

    /// Create (or set) the one active pairing code. `fixed` pins a known code
    /// (e.g. `--pair-code`); otherwise a random one is generated.
    @discardableResult
    public func mintCode(ttl: TimeInterval, fixed: String? = nil) -> String {
        let code = fixed?.uppercased() ?? Self.randomCode()
        lock.withLock { pending = (code, Date().addingTimeInterval(ttl)) }
        return code
    }

    /// Validate a code and, on success, issue + persist a device token.
    public func pair(code: String, device: String) -> String? {
        lock.withLock {
            guard let p = pending, Date() < p.expires,
                  Self.constantTimeEqual(code.uppercased(), p.code) else { return nil }
            let token = Self.randomToken()
            devices.append(Device(token: token, name: device, pairedAt: Date()))
            pending = nil                                   // single-use
            persist()
            return token
        }
    }

    /// Is this bearer token one we issued?
    public func authorize(_ token: String) -> Bool {
        lock.withLock { devices.contains { Self.constantTimeEqual($0.token, token) } }
    }

    /// Remove devices whose token starts with `prefix`. Returns how many.
    @discardableResult
    public func revoke(prefix: String) -> Int {
        lock.withLock {
            let before = devices.count
            devices.removeAll { $0.token.hasPrefix(prefix) }
            persist()
            return before - devices.count
        }
    }

    public func revokeAll() {
        lock.withLock { devices.removeAll(); persist() }
    }

    // MARK: Internals

    /// Caller must hold `lock`.
    private func persist() {
        if let data = try? JSONEncoder().encode(devices) { try? data.write(to: fileURL) }
    }

    /// Crockford-ish base32 (no ambiguous chars), grouped: `K7QP-2M9X-4RTD`.
    private static func randomCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        let chars = (0..<12).map { _ in alphabet.randomElement(using: &rng)! }
        return stride(from: 0, to: 12, by: 4)
            .map { String(chars[$0..<$0 + 4]) }
            .joined(separator: "-")
    }

    /// 128-bit random, hex-encoded.
    private static func randomToken() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
    }

    /// Length-aware, non-short-circuiting compare (no timing leak on match length).
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
