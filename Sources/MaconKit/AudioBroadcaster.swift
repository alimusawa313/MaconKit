//
//  AudioBroadcaster.swift
//  MaconKit
//
//  Fan-out for the encoded audio stream (Mac system audio → companions), the
//  same shape as ScreenBroadcaster minus the keyframe machinery: AAC packets
//  are independently decodable, so a dropped packet is a 21 ms blip, not a
//  corrupted stream.
//
//  Capture is demand-driven, like the screen: `onActive(true)` on the first
//  listener, `onActive(false)` when the last leaves — that's what flips the
//  Mac's default output onto the virtual speaker and back.
//
//  Wire packet (both directions, one WS binary frame each):
//    [1] codec     1 = AAC-LC @ 48 kHz
//    [1] channels  1 = mono, 2 = stereo
//    [4] seq       big-endian, wraps
//    [..] one encoded packet (one AAC access unit)
//

import Foundation

public final class AudioBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [ObjectIdentifier: @Sendable (Data) -> Void] = [:]

    /// Start/stop audio capture + routing (first listener / last leaves).
    public var onActive: (@Sendable (Bool) -> Void)?

    public init() {}

    public var listenerCount: Int {
        lock.lock(); defer { lock.unlock() }; return sinks.count
    }

    /// Called by the encoder for every encoded packet.
    public func publish(_ packet: Data) {
        lock.lock(); let current = Array(sinks.values); lock.unlock()
        for sink in current { sink(packet) }
    }

    func addListener(_ id: ObjectIdentifier, sink: @escaping @Sendable (Data) -> Void) {
        lock.lock(); let wasEmpty = sinks.isEmpty; sinks[id] = sink; lock.unlock()
        if wasEmpty { onActive?(true) }
    }

    func removeListener(_ id: ObjectIdentifier) {
        lock.lock(); sinks[id] = nil; let empty = sinks.isEmpty; lock.unlock()
        if empty { onActive?(false) }
    }
}

/// Helpers for the 6-byte audio packet header shared by both directions.
public enum AudioPacket {
    public static let headerSize = 6
    public static let codecAAC: UInt8 = 1

    public static func encode(codec: UInt8, channels: UInt8, seq: UInt32, payload: Data) -> Data {
        var out = Data(capacity: headerSize + payload.count)
        out.append(codec)
        out.append(channels)
        out.append(UInt8(truncatingIfNeeded: seq >> 24))
        out.append(UInt8(truncatingIfNeeded: seq >> 16))
        out.append(UInt8(truncatingIfNeeded: seq >> 8))
        out.append(UInt8(truncatingIfNeeded: seq))
        out.append(payload)
        return out
    }

    public static func decode(_ data: Data) -> (codec: UInt8, channels: UInt8, seq: UInt32, payload: Data)? {
        guard data.count > headerSize else { return nil }
        let b = [UInt8](data.prefix(headerSize))
        let seq = UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5])
        return (b[0], b[1], seq, data.dropFirst(headerSize))
    }
}

/// The Mac's answer to `GET /audio/status` — what the companion's media-I/O
/// toggles show as state and hints ("install the driver on your Mac", …).
public struct CompanionAudioStatusDTO: Codable, Sendable {
    /// MacONAudio.driver is installed and its devices are visible to Core Audio.
    public var driverActive: Bool
    /// The Mac allows streaming its system audio ("Share system audio").
    public var audioAllowed: Bool
    /// The Mac accepts a remote microphone ("Accept remote microphone").
    public var micAllowed: Bool
    /// How the downlink is produced: "routed" (virtual speaker — Mac is silent),
    /// "tap" (ScreenCaptureKit fallback — Mac speakers keep playing), "off".
    public var mode: String
    /// Devices currently listening to this Mac's audio.
    public var listeners: Int
    /// A companion mic is currently live as the Mac's input.
    public var micLive: Bool

    public init(driverActive: Bool, audioAllowed: Bool, micAllowed: Bool,
                mode: String, listeners: Int, micLive: Bool) {
        self.driverActive = driverActive
        self.audioAllowed = audioAllowed
        self.micAllowed = micAllowed
        self.mode = mode
        self.listeners = listeners
        self.micLive = micLive
    }
}
