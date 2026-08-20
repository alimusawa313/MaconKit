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
//    • only a SHA-256 of each token is written to disk, so the file cannot give
//      an attacker a working token back
//    • devices.json is 0600 inside a 0700 directory, written atomically
//    • a token idle longer than `idleWindow` stops working
//    • revocation is file-based, so it works even with no server running
//

import Foundation
import CryptoKit

public final class PairingStore: @unchecked Sendable {

    /// How long a token may go unused before it stops working. A captured token
    /// therefore has a shelf life, and a device someone stopped using (lost
    /// phone, sold iPad) drops off on its own.
    public static let idleWindow: TimeInterval = 30 * 24 * 3600

    public struct Device: Codable, Sendable, Identifiable {
        /// First 8 characters of the token. This is the handle everything else
        /// keys on: the Settings list, the fleet map, the push registry, and
        /// `macon companion revoke <short>`. Keeping 32 bits of a 128-bit token
        /// visible leaves 96 bits unguessable, which is the same trade a hosted
        /// API makes when it shows you a key's prefix but never the key.
        public var tokenShort: String
        /// SHA-256 of the token, hex. The token itself is never written to disk,
        /// so reading this file gets you nothing you can present as a bearer.
        public var tokenHash: String
        public var name: String
        public var pairedAt: Date
        /// Last time this token authorized a request. Idle past `idleWindow` and
        /// it is dropped. Persisted lazily (see `flushInterval`), so it costs no
        /// disk write per request.
        public var lastSeen: Date

        public var id: String { tokenShort }

        init(token: String, name: String, pairedAt: Date, lastSeen: Date) {
            self.tokenShort = String(token.prefix(8))
            self.tokenHash = PairingStore.hash(token)
            self.name = name
            self.pairedAt = pairedAt
            self.lastSeen = lastSeen
        }

        private enum CodingKeys: String, CodingKey {
            case tokenShort, tokenHash, name, pairedAt, lastSeen
            /// Only ever decoded: this is what builds before the hashing change
            /// wrote. Never encoded again (see `encode(to:)`).
            case token
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "device"
            pairedAt = try c.decodeIfPresent(Date.self, forKey: .pairedAt) ?? Date()
            if let hash = try c.decodeIfPresent(String.self, forKey: .tokenHash) {
                tokenHash = hash
                tokenShort = try c.decodeIfPresent(String.self, forKey: .tokenShort) ?? String(hash.prefix(8))
                lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? pairedAt
            } else if let legacy = try c.decodeIfPresent(String.self, forKey: .token) {
                // A file from before the hashing change, holding the token
                // itself. Keep the pairing working, hash it, and keep the handle
                // the UI and the push registry already show. lastSeen starts now
                // rather than at pairedAt: we have no usage history for this
                // device, and dating it from the pairing would expire a token
                // that is in use every day.
                tokenHash = PairingStore.hash(legacy)
                tokenShort = String(legacy.prefix(8))
                lastSeen = Date()
            } else {
                throw DecodingError.dataCorruptedError(forKey: .tokenHash, in: c,
                                                       debugDescription: "device has neither tokenHash nor token")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(tokenShort, forKey: .tokenShort)
            try c.encode(tokenHash, forKey: .tokenHash)
            try c.encode(name, forKey: .name)
            try c.encode(pairedAt, forKey: .pairedAt)
            try c.encode(lastSeen, forKey: .lastSeen)
        }
    }

    private let lock = NSLock()
    private var pending: (code: String, expires: Date)?
    private var devices: [Device]
    /// Modification date of devices.json when we last loaded it, so a change
    /// made by another process (e.g. `macon pair` / `macon companion revoke`
    /// while the app's server is running) is picked up on the next authorize.
    private var loadedAt: Date?
    /// When we last wrote `lastSeen` through to disk. Authorizing happens on
    /// every request, so the timestamp lives in memory between flushes.
    private var lastFlush = Date.distantPast
    /// How stale on-disk `lastSeen` may get. Anything well under `idleWindow`
    /// costs nothing in accuracy.
    private static let flushInterval: TimeInterval = 15 * 60

    private let fileURL: URL

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacON/companion", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // An install from before this change left the directory 0755 and the
        // file 0644, i.e. every token readable by every other local account.
        // Tighten both on the way past, not just on the ones we create.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        fileURL = dir.appendingPathComponent("devices.json")
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        devices = []
        reloadLocked()
    }

    public var deviceCount: Int { lock.withLock { reloadIfChanged(); pruneIdle(); return devices.count } }
    public func deviceList() -> [Device] { lock.withLock { reloadIfChanged(); pruneIdle(); return devices } }

    // MARK: Pairing

    /// Create (or set) the one active pairing code. `fixed` pins a known code
    /// (e.g. `--pair-code`); otherwise a random one is generated.
    @discardableResult
    public func mintCode(ttl: TimeInterval, fixed: String? = nil) -> String {
        let code = fixed?.uppercased() ?? Self.randomCode()
        lock.withLock { pending = (code, Date().addingTimeInterval(ttl)) }
        return code
    }

    /// Validate a code and, on success, issue + persist a device token. The
    /// token is returned to the caller once, here, and never stored in a form
    /// anything can read back.
    public func pair(code: String, device: String) -> String? {
        lock.withLock {
            guard let p = pending, Date() < p.expires,
                  Self.constantTimeEqual(code.uppercased(), p.code) else { return nil }
            let token = Self.randomToken()
            let now = Date()
            devices.append(Device(token: token, name: device, pairedAt: now, lastSeen: now))
            pending = nil                                   // single-use
            persist()
            return token
        }
    }

    /// Is this bearer token one we issued, and still live? Reloads from disk
    /// first if another process changed the file, so pair/revoke work across
    /// processes.
    public func authorize(_ token: String) -> Bool {
        lock.withLock {
            reloadIfChanged()
            pruneIdle()
            let hash = Self.hash(token)
            guard let i = devices.firstIndex(where: { Self.constantTimeEqual($0.tokenHash, hash) }) else {
                return false
            }
            devices[i].lastSeen = Date()
            if Date().timeIntervalSince(lastFlush) > Self.flushInterval { persist() }
            return true
        }
    }

    /// Remove devices whose handle starts with `prefix`. Returns how many.
    @discardableResult
    public func revoke(prefix: String) -> Int {
        lock.withLock {
            reloadIfChanged()
            let before = devices.count
            devices.removeAll { $0.tokenShort.hasPrefix(prefix) }
            persist()
            return before - devices.count
        }
    }

    /// Remove the device holding exactly this token (the /unpair route, where
    /// the caller presents the token itself rather than its handle).
    @discardableResult
    public func revoke(token: String) -> Int {
        lock.withLock {
            reloadIfChanged()
            let hash = Self.hash(token)
            let before = devices.count
            devices.removeAll { Self.constantTimeEqual($0.tokenHash, hash) }
            persist()
            return before - devices.count
        }
    }

    public func revokeAll() {
        lock.withLock { devices.removeAll(); persist() }
    }

    // MARK: Internals

    /// Caller must hold `lock`. Drop anything idle past the window. Runs before
    /// every match, so an expired token is gone before it can authorize.
    private func pruneIdle() {
        let cutoff = Date().addingTimeInterval(-Self.idleWindow)
        let before = devices.count
        devices.removeAll { $0.lastSeen < cutoff }
        if devices.count != before { persist() }
    }

    /// Caller must hold `lock`. Written through a 0600 temp file and swapped
    /// into place, so the tokens' hashes are never briefly world-readable and a
    /// crash mid-write cannot leave a truncated file (which would silently drop
    /// every pairing).
    private func persist() {
        lastFlush = Date()
        guard let data = try? JSONEncoder().encode(devices) else { return }
        let fm = FileManager.default
        let perms: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        defer { loadedAt = fileModDate() }

        guard fm.fileExists(atPath: fileURL.path) else {
            _ = fm.createFile(atPath: fileURL.path, contents: data, attributes: perms)
            return
        }
        let tmp = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".devices.\(UUID().uuidString).json")
        // createFile applies the mode as the file comes into being, so there is
        // no window where it exists at the default 0644.
        if fm.createFile(atPath: tmp.path, contents: data, attributes: perms),
           (try? fm.replaceItemAt(fileURL, withItemAt: tmp, backupItemName: nil,
                                  options: [.usingNewMetadataOnly])) != nil {
            return
        }
        try? fm.removeItem(at: tmp)
        try? data.write(to: fileURL)
        try? fm.setAttributes(perms, ofItemAtPath: fileURL.path)
    }

    /// Caller must hold `lock`. Re-read devices.json if its mtime moved.
    private func reloadIfChanged() {
        guard fileModDate() != loadedAt else { return }
        reloadLocked()
    }

    /// Caller must hold `lock` (or be in init).
    private func reloadLocked() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Device].self, from: data) else {
            loadedAt = fileModDate()
            return
        }
        devices = list
        // An older build wrote the tokens themselves. Decoding hashed them;
        // write the file back so the plaintext leaves the disk for good.
        if Self.holdsPlaintextTokens(data) {
            persist()
            return                                  // persist() refreshed loadedAt
        }
        loadedAt = fileModDate()
    }

    private struct LegacyProbe: Decodable { let token: String? }

    private static func holdsPlaintextTokens(_ data: Data) -> Bool {
        guard let probe = try? JSONDecoder().decode([LegacyProbe].self, from: data) else { return false }
        return probe.contains { $0.token != nil }
    }

    private func fileModDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
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

    /// SHA-256, hex. No salt and no stretching on purpose: the input is 128 bits
    /// of CSPRNG output, so there is no dictionary to run and nothing for a KDF
    /// to slow down, and every request has to hash a token to authorize.
    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
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
