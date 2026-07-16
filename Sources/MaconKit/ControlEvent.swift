//
//  ControlEvent.swift
//  MaconKit
//
//  Input events sent iPad → Mac over the /control WebSocket. Coordinates are
//  normalized (0…1) over the Mac's main display, so the phone needn't know the
//  Mac's resolution. Decoded here; injected as CGEvents by the app.
//

import Foundation

public struct ControlEvent: Codable, Sendable {
    /// "move" | "movedelta" | "mouse" | "click" | "scroll" | "text" | "key" |
    /// "combo" | "media" | "volume" | "fps" | "res" | "launch" (s = .app path)
    public var t: String
    public var x: Double?          // normalized cursor position
    public var y: Double?
    public var button: String?     // "left" | "right"
    public var count: Int?         // click count (1 = single, 2 = double)
    public var dx: Double?         // scroll delta (points)
    public var dy: Double?
    public var s: String?          // typed text (unicode)
    public var code: Int?          // virtual key code (key / combo)
    public var down: Bool?         // key down vs up
    public var mods: [String]?     // "cmd" | "ctrl" | "opt" | "shift" (combo chords)
    public var v: Double?          // 0…1 value (volume)
    public var w: Int?             // window id — map x/y over this window's bounds
                                   // instead of the display (CompactOS)

    public init(t: String) { self.t = t }
}
