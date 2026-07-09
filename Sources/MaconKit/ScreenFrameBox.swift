//
//  ScreenFrameBox.swift
//  MaconKit
//
//  Thread-safe hand-off for the latest encoded screen frame: the platform
//  screen streamer writes frames in; the companion server reads the newest one
//  and pushes it to viewers. A sequence number lets the server skip re-sending
//  an unchanged frame.
//

import Foundation

public final class ScreenFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var seq = 0
    private var data: Data?

    public init() {}

    /// Store a newly encoded frame (e.g. a JPEG).
    public func set(_ frame: Data) {
        lock.lock(); seq &+= 1; data = frame; lock.unlock()
    }

    /// Drop the current frame (e.g. when capture stops).
    public func clear() {
        lock.lock(); data = nil; lock.unlock()
    }

    /// The latest frame and its sequence, or nil if none has arrived yet.
    public func latest() -> (seq: Int, data: Data)? {
        lock.lock(); defer { lock.unlock() }
        guard let data else { return nil }
        return (seq, data)
    }
}
