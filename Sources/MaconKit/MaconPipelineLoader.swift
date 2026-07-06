//
//  MaconPipelineLoader.swift
//  MaconKit
//
//  Loads and parses a macon.yml. Shared by the app and the CLI. YAML is converted
//  to JSON via Ruby (present wherever fastlane runs) so there's no YAML dependency.
//

import Foundation

public enum MaconPipelineLoader {

    /// Parse a macon.yml at `path` into a `MaconPipeline`, or nil if missing/invalid.
    public static func load(atPath path: String) -> MaconPipeline? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc",
            "ruby -ryaml -rjson -e 'puts JSON.generate(YAML.load_file(ARGV[0]))' \"\(path)\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let pipeline = try? JSONDecoder().decode(MaconPipeline.self, from: data),
              pipeline.hasContent else { return nil }
        return pipeline
    }
}
