//
//  CloudCommandGate.swift
//  MaconKit
//
//  Freshness and replay rules for the iCloud command channel (wake, unlock,
//  lock, privacy, tunnel, start).
//
//  That channel carries no bearer token. Writing one record in the owner's
//  private CloudKit database is the whole authorization, so these rules are the
//  only thing between a stale or repeated row and the Mac typing its login
//  password. They live here, apart from CloudKit, so they can be exercised
//  directly instead of only in production.
//
//  Both pieces of state have to be persisted by the caller. Keeping them in
//  memory is what let a relaunch re-run whatever command was last left in the
//  database.
//

import Foundation

public struct CloudCommandGate: Sendable {

    public enum Verdict: Equatable, Sendable {
        /// Fresh, unrepeated, newer than anything already run.
        case run
        /// Already consumed. Expected on every poll, so say nothing about it.
        case seen
        /// Refused, with a reason worth logging.
        case refused(String)
    }

    /// How old a command may be before it is refused.
    public static let freshness: TimeInterval = 60
    /// How far a device's clock may run ahead of ours and still be believed.
    public static let skew: TimeInterval = 60

    /// The nonce last consumed, whether or not it was allowed to run.
    public private(set) var lastNonce: String?
    /// The newest `issuedAt` acted on. A command has to beat it, which is what
    /// makes a replay after a restart impossible rather than merely unlikely.
    public private(set) var highWater: Date

    /// `highWater` of `.distantPast` (or the 0 a missing UserDefaults double
    /// decodes to) means nothing has run yet, so the first command passes.
    public init(lastNonce: String? = nil, highWater: Date = .distantPast) {
        self.lastNonce = lastNonce
        self.highWater = highWater
    }

    /// Decide on one command record, consuming its nonce either way: a command
    /// this refuses must not get another look on the next poll, or after a
    /// restart.
    public mutating func admit(nonce: String, issuedAt: Date?, now: Date = Date()) -> Verdict {
        guard nonce != lastNonce else { return .seen }
        lastNonce = nonce

        // A missing or unreadable timestamp is a refusal, not a pass. This read
        // "if let issued, and it is older than 60s, return", so leaving the
        // field out skipped the check entirely and the command ran at any age.
        guard let issuedAt else { return .refused("it carried no issuedAt") }

        let age = now.timeIntervalSince(issuedAt)
        guard age <= Self.freshness else { return .refused("it was \(Int(age))s old") }
        // A future-dated command is not one we can reason about, and accepting
        // it would drag the high-water mark forward and lock out honest ones
        // until the clock caught up.
        guard age >= -Self.skew else { return .refused("it is dated in the future") }
        guard issuedAt > highWater else { return .refused("a newer command has already run") }

        highWater = issuedAt
        return .run
    }
}
