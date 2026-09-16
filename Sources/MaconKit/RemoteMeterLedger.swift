//
//  RemoteMeterLedger.swift
//  MaconKit
//
//  The free tier's daily remote allowance, kept where it can't be argued
//  with: on the Mac. Only remote screen and control time counts, LAN time is
//  free and build monitoring never counts; the companion decides what to
//  send, this decides what today adds up to.
//
//  One ledger per Mac, not per device, so an iPhone and an iPad paired to
//  the same Mac share the same 40 minutes, and the day rolls over at this
//  Mac's midnight rather than at whatever the phone's clock says. Served by
//  GET/POST /pro/meter; a companion that gets a 404 from an older runner
//  keeps its own tally instead, which is the honest degrade.
//

import Foundation

/// What the companion reads back: seconds spent today, the ceiling, and when
/// the day rolls over on this Mac.
public struct CompanionRemoteMeterDTO: Codable, Sendable {
    public var usedSeconds: Int
    public var limitSeconds: Int
    public var resetsAt: Date
}

public actor RemoteMeterLedger {

    /// 40 minutes a day. The companion carries the same default for runners
    /// that predate this route.
    public static let limitSeconds = 40 * 60

    /// A single report can't claim more than this. The companion flushes in
    /// half-minute batches and at most a few minutes on session end, so
    /// anything larger is a bug or a forgery, and is clamped, not trusted.
    private static let maxReport = 10 * 60

    private struct Day: Codable {
        var day: String
        var seconds: Int
    }

    private let fileURL: URL
    private var current: Day

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacON/companion", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        fileURL = dir.appendingPathComponent("remote-meter.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(Day.self, from: data) {
            current = saved
        } else {
            current = Day(day: Self.today(), seconds: 0)
        }
    }

    /// Today's ledger, rolled over if the date has moved on since the last call.
    public func info() -> CompanionRemoteMeterDTO {
        rollOver()
        return CompanionRemoteMeterDTO(usedSeconds: current.seconds,
                                       limitSeconds: Self.limitSeconds,
                                       resetsAt: Self.nextMidnight())
    }

    /// Add a companion's report of remote seconds and return the new ledger.
    /// Negative, absurd or non-finite reports add nothing.
    public func add(seconds: Int) -> CompanionRemoteMeterDTO {
        rollOver()
        let clamped = max(0, min(seconds, Self.maxReport))
        // No point counting past a day; the ceiling is the only number that
        // matters and this keeps a stuck client from growing the file forever.
        current.seconds = min(current.seconds + clamped, 24 * 60 * 60)
        persist()
        return info()
    }

    // MARK: Days

    private func rollOver() {
        let today = Self.today()
        guard current.day != today else { return }
        current = Day(day: today, seconds: 0)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(current) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// The Mac's own calendar day. Local time on purpose: "it comes back at
    /// midnight" should mean the midnight the person at the desk experiences.
    private static func today() -> String {
        let f = DateFormatter()
        f.calendar = .current
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func nextMidnight() -> Date {
        Calendar.current.nextDate(after: Date(),
                                  matching: DateComponents(hour: 0, minute: 0, second: 0),
                                  matchingPolicy: .nextTime) ?? Date().addingTimeInterval(24 * 60 * 60)
    }
}
