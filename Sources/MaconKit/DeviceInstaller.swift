//
//  DeviceInstaller.swift
//  MaconKit
//
//  Putting a freshly built app onto a real iPhone or iPad, straight from the
//  Mac that built it. Xcode's `devicectl` does the work: it knows every device
//  paired with this Mac, over USB or Wi-Fi, and can install a development
//  signed .app and launch it. So a pipeline step can end with the app on your
//  phone, no TestFlight round trip, and the companion can ask for the same
//  install again later from the build's page.
//
//  Needs: the device paired with Xcode once, Developer Mode on, and the app
//  signed for that device (a development profile that lists it). Those are
//  the same things Xcode's Run button needs.
//

import Foundation

/// A device Xcode knows about, as `devicectl list devices` reports it.
public struct HardwareDevice: Codable, Sendable, Identifiable, Hashable {
    /// devicectl's identifier (a UUID string). What install commands take.
    public var id: String
    /// The name the person gave it ("Ali's iPhone").
    public var name: String
    /// Marketing name ("iPhone 17 Pro").
    public var model: String
    /// "iOS", "iPadOS", "watchOS", "xrOS", …
    public var platform: String
    public var osVersion: String
    /// Reachable right now (USB or the same Wi-Fi), so an install can start.
    public var connected: Bool
    public var developerMode: Bool

    public init(id: String, name: String, model: String, platform: String, osVersion: String,
                connected: Bool, developerMode: Bool) {
        self.id = id; self.name = name; self.model = model; self.platform = platform
        self.osVersion = osVersion; self.connected = connected; self.developerMode = developerMode
    }

    /// Something an app can be installed on (not a watch, not a Mac).
    public var installable: Bool {
        let p = platform.lowercased()
        return p.hasPrefix("ios") || p.hasPrefix("ipados") || p.hasPrefix("xros") || p.hasPrefix("visionos") || p.hasPrefix("tvos")
    }
}

/// What a step produced and where it went, kept with the run so the build's
/// page can offer "install this again".
public struct RunProduct: Codable, Sendable, Hashable {
    /// Absolute path of the .app on this Mac.
    public var path: String
    public var bundleId: String
    /// The bundle's display name, for the button.
    public var name: String
    /// The device name it was installed on during the run, if any.
    public var installedOn: String?

    public init(path: String, bundleId: String, name: String, installedOn: String? = nil) {
        self.path = path; self.bundleId = bundleId; self.name = name; self.installedOn = installedOn
    }
}

public enum DeviceInstaller {

    // MARK: Devices

    /// Every device Xcode has paired, connected or not. Empty when devicectl is
    /// missing (no Xcode) or nothing is paired.
    public static func list() async -> [HardwareDevice] {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("macon-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        let code = await runQuiet(["xcrun", "devicectl", "list", "devices", "--timeout", "10",
                                   "--json-output", out.path])
        guard code == 0, let data = try? Data(contentsOf: out),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { d in
            guard let id = d["identifier"] as? String else { return nil }
            let props = d["deviceProperties"] as? [String: Any] ?? [:]
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            let conn = d["connectionProperties"] as? [String: Any] ?? [:]
            let tunnel = (conn["tunnelState"] as? String ?? "").lowercased()
            return HardwareDevice(
                id: id,
                name: props["name"] as? String ?? hw["marketingName"] as? String ?? "Device",
                model: hw["marketingName"] as? String ?? hw["productType"] as? String ?? "",
                platform: hw["platform"] as? String ?? "",
                osVersion: props["osVersionNumber"] as? String ?? "",
                connected: tunnel == "connected",
                developerMode: (props["developerModeStatus"] as? String ?? "").lowercased() == "enabled")
        }
    }

    /// The device to install on when a step names none: `MACON_INSTALL_DEVICE`
    /// from the environment, else the one connected phone or tablet.
    public static func defaultDevice(env: [String: String]) async -> String? {
        if let named = env["MACON_INSTALL_DEVICE"], !named.isEmpty { return named }
        let candidates = await list().filter { $0.installable && $0.connected }
        return candidates.count == 1 ? candidates[0].id : candidates.first?.id
    }

    // MARK: Products

    /// Resolve `pattern` (a path or glob, relative to `cwd`) to one .app,
    /// the newest when several match.
    public static func resolveApp(_ pattern: String, cwd: String) -> String? {
        var expanded = (pattern as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/") { expanded = (cwd as NSString).appendingPathComponent(expanded) }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(expanded, GLOB_TILDE | GLOB_BRACE | GLOB_MARK, nil, &g) == 0 else { return nil }
        var matches: [(String, Date)] = []
        for i in 0..<Int(g.gl_matchc) {
            guard let c = g.gl_pathv[i], var path = String(validatingUTF8: c) else { continue }
            if path.hasSuffix("/") { path.removeLast() }
            guard path.hasSuffix(".app") else { continue }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            matches.append((path, mtime))
        }
        return matches.max { $0.1 < $1.1 }?.0
    }

    /// The product's identity, read from its Info.plist.
    public static func product(at app: String) -> RunProduct? {
        let plist = (app as NSString).appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plist),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let bundleId = info["CFBundleIdentifier"] as? String else { return nil }
        let name = info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        return RunProduct(path: app, bundleId: bundleId, name: name)
    }

    // MARK: Install

    /// Install (and launch) an app on a device. `device` is anything devicectl
    /// accepts: identifier, UDID, or the device's name. Lines go to `onLine`;
    /// the return is devicectl's exit code, 0 on success.
    @discardableResult
    public static func install(app: String, device: String, launch: Bool,
                               onLine: @escaping @Sendable (String) -> Void) async -> Int32 {
        onLine("📲 Installing \((app as NSString).lastPathComponent) on \(device)…")
        let code = await Shell.run(
            "xcrun devicectl device install app --device \(quoted(device)) \(quoted(app)) --timeout 300",
            cwd: "", onLine: onLine)
        guard code == 0 else {
            onLine("✗ Install failed (exit \(code)). Is the device unlocked, paired with Xcode, in Developer Mode, and is the app signed for it?")
            return code
        }
        guard launch, let bundleId = product(at: app)?.bundleId else { return 0 }
        onLine("▶︎ Launching \(bundleId)…")
        let launched = await Shell.run(
            "xcrun devicectl device process launch --terminate-existing --device \(quoted(device)) \(quoted(bundleId)) --timeout 60",
            cwd: "", onLine: onLine)
        if launched != 0 { onLine("⚠︎ Installed, but launching failed (exit \(launched)). Tap the icon on the device.") }
        return 0   // the install itself succeeded; a launch hiccup is not a failed step
    }

    // MARK: Helpers

    static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run a command with no shell and no output, for tools that write their
    /// answer to a file.
    private static func runQuiet(_ argv: [String]) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = argv
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(returning: -1) }
        }
    }
}
