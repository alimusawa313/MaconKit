//
//  ScreenBroadcaster.swift
//  MaconKit
//
//  Fan-out for the H.264 screen stream. The encoder publishes each encoded
//  packet; the companion server registers a sink per connected viewer. Unlike
//  a still-frame feed, video is a delta stream — packets must be delivered in
//  order, so this pushes every packet rather than sampling "the latest".
//
//  Capture is demand-driven: `onActive(true)` fires on the first viewer,
//  `onActive(false)` when the last leaves. `onNeedKeyframe` asks the encoder for
//  an IDR so a newly-joined (or recovering) viewer can start decoding.
//

import Foundation

public final class ScreenBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [ObjectIdentifier: @Sendable (Data) -> Void] = [:]
    private var sentCount = 0
    private var droppedCount = 0

    /// Start/stop screen capture (first viewer arrives / last leaves).
    public var onActive: (@Sendable (Bool) -> Void)?
    /// Request an IDR frame (new viewer joined, or a viewer fell behind).
    public var onNeedKeyframe: (@Sendable () -> Void)?

    public init() {}

    // MARK: Delivery stats (fed by the server, polled by the bitrate controller)

    public func noteSent() { lock.lock(); sentCount += 1; lock.unlock() }
    public func noteDropped() { lock.lock(); droppedCount += 1; lock.unlock() }

    /// Return and reset the counters — one adaptation window.
    public func takeStats() -> (sent: Int, dropped: Int) {
        lock.lock(); defer { sentCount = 0; droppedCount = 0; lock.unlock() }
        return (sentCount, droppedCount)
    }

    /// Called by the encoder for every encoded packet.
    public func publish(_ packet: Data) {
        lock.lock(); let current = Array(sinks.values); lock.unlock()
        for sink in current { sink(packet) }
    }

    func addViewer(_ id: ObjectIdentifier, sink: @escaping @Sendable (Data) -> Void) {
        lock.lock(); let wasEmpty = sinks.isEmpty; sinks[id] = sink; lock.unlock()
        if wasEmpty { onActive?(true) }
        onNeedKeyframe?()
    }

    func removeViewer(_ id: ObjectIdentifier) {
        lock.lock(); sinks[id] = nil; let empty = sinks.isEmpty; lock.unlock()
        if empty { onActive?(false) }
    }
}
