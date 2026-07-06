//
//  JavaLocator.swift
//  MacON
//
//  Finds the newest installed JDK so the runner uses a Java new enough for it.
//
//  Why this exists: the Bitbucket Pipelines runner ships compiled for a specific
//  Java (e.g. runner 6.0.4 → Java 25 / class file 69). macOS's /usr/bin/java stub
//  picks whatever JDK is registered in /Library/Java, which is often older and
//  fails with UnsupportedClassVersionError. Rather than depend on the user's
//  shell profile, MacON points the runner at the best JDK it can find.
//

import Foundation

enum JavaLocator {

    struct JDK: Sendable {
        let home: String
        let major: Int
        let version: String
    }

    /// The highest-versioned JDK found on this Mac, or nil if none discovered.
    static func bestJDK() -> JDK? {
        candidateHomes()
            .compactMap(versioned)
            .max { $0.major < $1.major }
    }

    // MARK: - Discovery

    private static func candidateHomes() -> [String] {
        let fm = FileManager.default
        var homes: [String] = []

        // Homebrew keg-only openjdk installs (Apple Silicon + Intel prefixes).
        for base in ["/opt/homebrew/opt", "/usr/local/opt"] {
            if let entries = try? fm.contentsOfDirectory(atPath: base) {
                for e in entries where e == "openjdk" || e.hasPrefix("openjdk@") {
                    homes.append("\(base)/\(e)/libexec/openjdk.jdk/Contents/Home")
                }
            }
        }

        // System + user JVM registries (Temurin, Oracle, symlinked kegs, …).
        let jvmRoots = [
            "/Library/Java/JavaVirtualMachines",
            fm.homeDirectoryForCurrentUser.path + "/Library/Java/JavaVirtualMachines",
        ]
        for base in jvmRoots {
            if let entries = try? fm.contentsOfDirectory(atPath: base) {
                for e in entries {
                    homes.append("\(base)/\(e)/Contents/Home")
                }
            }
        }

        return homes.filter { fm.fileExists(atPath: "\($0)/bin/java") }
    }

    /// Parse the JDK's `release` file for its version.
    private static func versioned(_ home: String) -> JDK? {
        guard let content = try? String(contentsOfFile: "\(home)/release", encoding: .utf8),
              let line = content.split(separator: "\n")
                  .first(where: { $0.hasPrefix("JAVA_VERSION=") })
        else { return nil }

        let version = line
            .replacingOccurrences(of: "JAVA_VERSION=", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespaces)

        return JDK(home: home, major: majorVersion(version), version: version)
    }

    /// "25.0.3" → 25, legacy "1.8.0_411" → 8.
    private static func majorVersion(_ v: String) -> Int {
        let parts = v.split(separator: ".")
        if v.hasPrefix("1."), parts.count > 1 { return Int(parts[1]) ?? 0 }
        return Int(parts.first ?? "0") ?? 0
    }
}
