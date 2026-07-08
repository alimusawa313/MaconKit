import Foundation
import Combine
import MaconKit

// Tiny zero-dependency CLI over the shared MaconKit core.
// Usage:
//   macon version
//   macon lint [path]                       inspect a macon.yml
//   macon run [--workflow NAME] [--branch B] [path]   run a workflow here
//   macon watch --workspace WS --repo SLUG  poll Bitbucket & build here

// Line-buffer stdout so `macon watch` logs appear promptly when redirected to a
// file or pipe (nohup/tmux/launchd), not just when attached to a terminal.
setvbuf(stdout, nil, _IOLBF, 0)

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }

/// Whether a bare boolean flag (e.g. `--prs`) is present.
func flag(_ name: String) -> Bool { args.contains("--\(name)") }

/// A stable UUID derived from a string, so a given repo/branch keeps the same
/// on-disk history folder and "last built" baseline across `macon watch` restarts.
func stableID(_ s: String) -> UUID {
    func fnv(_ salt: String) -> UInt64 {
        var h: UInt64 = 14695981039346656037
        for b in (s + salt).utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }
    let hi = fnv(""), lo = fnv("|macon")
    let hex = (0..<8).map { String(format: "%02x", UInt8((hi >> (UInt64($0) * 8)) & 0xff)) }.joined()
            + (0..<8).map { String(format: "%02x", UInt8((lo >> (UInt64($0) * 8)) & 0xff)) }.joined()
    let c = Array(hex)
    func slice(_ a: Int, _ b: Int) -> String { String(c[a..<b]) }
    return UUID(uuidString: "\(slice(0,8))-\(slice(8,12))-\(slice(12,16))-\(slice(16,20))-\(slice(20,32))") ?? UUID()
}

/// Capture the trimmed stdout of a command (for git metadata).
func capture(_ command: String, cwd: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", command]
    p.currentDirectoryURL = URL(fileURLWithPath: cwd)
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run(); p.waitUntilExit() } catch { return "" }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Run a command; return its exit code and merged stdout+stderr. Used by `init`
/// to detect a tool reliably — presence is the exit code, not "did it print".
func probe(_ command: String) -> (code: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", command]
    let out = Pipe(); p.standardOutput = out; p.standardError = out
    do { try p.run(); p.waitUntilExit() } catch { return (-1, "") }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (p.terminationStatus, s)
}

/// Normalize an Apple platform name to the casing Xcode/simctl expect.
func normalizePlatform(_ s: String) -> String {
    switch s.lowercased() {
    case "ios":                 return "iOS"
    case "watchos":             return "watchOS"
    case "tvos":                return "tvOS"
    case "visionos", "xros":    return "visionOS"
    case "macos", "osx":        return "macOS"
    default:                    return s
    }
}

/// Print installed simulator runtimes (all Apple platforms) and device types.
/// `full` lists every device type; otherwise just a count (keeps `init` tidy).
func showSimulators(full: Bool) {
    // Match runtime/devicetype lines by their CoreSimulator identifier, so every
    // platform (iOS, watchOS, tvOS, visionOS) is included — not just iOS.
    let rtRaw = capture("xcrun simctl list runtimes 2>/dev/null | grep -i simruntime", cwd: ".")
    let runtimes = rtRaw.split(separator: "\n").compactMap {
        $0.components(separatedBy: " (").first?.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    if runtimes.isEmpty {
        print("  Simulator runtimes: none — add one with `macon sims install <platform> [version]`")
    } else {
        print("  Simulator runtimes: \(runtimes.joined(separator: ", "))")
    }
    let dtRaw = capture("xcrun simctl list devicetypes 2>/dev/null | grep -i simdevicetype", cwd: ".")
    var seen = Set<String>()
    let types = dtRaw.split(separator: "\n").compactMap { line -> String? in
        // Keep the full name; drop only the trailing " (com.apple…SimDeviceType…)" id.
        let s = String(line)
        let name = (s.range(of: " (com.apple").map { String(s[..<$0.lowerBound]) } ?? s)
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, seen.insert(name).inserted else { return nil }
        return name
    }
    if full {
        print("  Device types (\(types.count)):")
        for t in types { print("    • \(t)") }
    } else {
        print("  Device types: \(types.count) available — see `macon sims list`")
    }
}

/// Parse `--flag value` options and a trailing positional argument.
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}
var positional: String? {
    // last arg (after the command) that isn't a flag or a flag's value.
    // Plain loop — avoids EnumeratedSequence collection APIs that vary by toolchain.
    var skip = Set<Int>()
    for (i, a) in args.enumerated() where a.hasPrefix("--") { skip.insert(i); skip.insert(i + 1) }
    var result: String?
    for (i, a) in args.enumerated() {
        if i == 0 { continue }                      // the command itself
        if skip.contains(i) || a.hasPrefix("--") { continue }
        result = a
    }
    return result
}

switch command {
case "version", "--version", "-v":
    print("macon \(maconVersion)")

case "lint":
    let path = positional ?? "macon.yml"
    guard let pipeline = MaconPipelineLoader.load(atPath: path) else {
        fail("Could not load or parse \(path) (needs Ruby for YAML→JSON).")
    }
    print("✓ \(path) — \(pipeline.name ?? "unnamed")")
    for (name, wf) in (pipeline.workflows ?? [:]).sorted(by: { $0.key < $1.key }) {
        let before = wf.before_run?.joined(separator: ", ") ?? ""
        print("  workflow \(name)" + (before.isEmpty ? "" : "  [before: \(before)]"))
        for step in wf.steps ?? [] { print("    • \(step.name)") }
    }
    for step in pipeline.steps ?? [] { print("  • \(step.name)") }
    for t in pipeline.triggers ?? [] {
        let m = t.pull_request.map { "PR→\($0)" } ?? t.branch.map { "branch \($0)" } ?? "?"
        print("  trigger \(m) ⇒ \(t.workflow)")
    }

case "run":
    let dir = positional ?? "."
    let file = option("file") ?? "macon.yml"
    let ymlPath = dir == "." ? file : "\(dir)/\(file)"
    guard let pipeline = MaconPipelineLoader.load(atPath: ymlPath) else {
        fail("No pipeline at \(ymlPath).")
    }
    let sha = capture("git rev-parse HEAD 2>/dev/null", cwd: dir)
    let branch = option("branch") ?? capture("git rev-parse --abbrev-ref HEAD 2>/dev/null", cwd: dir)
    var env: [String: String] = ["CI": "true"]
    if !sha.isEmpty { env["MACON_COMMIT"] = sha; env["MACON_COMMIT_SHORT"] = String(sha.prefix(8)) }
    if !branch.isEmpty { env["MACON_BRANCH"] = branch }

    let options = PipelineExecutor.Options(
        workingDirectory: dir,
        workflowName: option("workflow"),
        branch: branch.isEmpty ? nil : branch,
        env: env)

    let code = await PipelineExecutor.run(pipeline, options: options) { line in
        print(line)
    }
    exit(code)

case "init", "doctor":
    // Check the toolchain an iOS build needs; install what can be installed via
    // Homebrew. `--check` reports only (no installs).
    let checkOnly = flag("check")
    print("macon init — checking iOS CI prerequisites\n")

    let hasBrew = probe("command -v brew").code == 0

    struct Dep {
        let name: String
        let probe: String        // exits 0 when present; first output line is the version
        let install: String?     // auto-install command (nil = manual only)
        let hint: String         // shown when missing
        var gui = false          // install opens a GUI / can't be confirmed inline
    }

    let deps: [Dep] = [
        Dep(name: "Homebrew", probe: "brew --version", install: nil,
            hint: "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""),
        Dep(name: "Xcode Command Line Tools", probe: "xcode-select -p",
            install: "xcode-select --install",
            hint: "xcode-select --install (a system dialog will open)", gui: true),
        Dep(name: "Xcode", probe: "xcodebuild -version", install: nil,
            hint: "Install Xcode from the App Store, then: sudo xcodebuild -license accept"),
        Dep(name: "git", probe: "git --version", install: nil,
            hint: "Ships with the Xcode Command Line Tools."),
        Dep(name: "Ruby", probe: "ruby -v", install: nil,
            hint: "System Ruby usually works; or `brew install ruby`."),
        Dep(name: "Bundler", probe: "bundle -v", install: nil,
            hint: "gem install bundler  (may need sudo on system Ruby)"),
        Dep(name: "fastlane", probe: "fastlane --version 2>&1 | grep -iE '^fastlane [0-9]'",
            install: hasBrew ? "brew install fastlane" : nil, hint: "brew install fastlane"),
        Dep(name: "SwiftLint", probe: "swiftlint version",
            install: hasBrew ? "brew install swiftlint" : nil, hint: "brew install swiftlint"),
        Dep(name: "gitleaks", probe: "gitleaks version",
            install: hasBrew ? "brew install gitleaks" : nil, hint: "brew install gitleaks"),
        Dep(name: "JDK (Bitbucket runner)", probe: "/usr/libexec/java_home",
            install: hasBrew ? "brew install openjdk@25" : nil, hint: "brew install openjdk@25"),
        Dep(name: "cloudflared (webhook tunnel, optional)", probe: "command -v cloudflared",
            install: hasBrew ? "brew install cloudflared" : nil, hint: "brew install cloudflared"),
    ]

    var missing: [Dep] = []
    for d in deps {
        let r = probe(d.probe)
        if r.code == 0 && !r.output.isEmpty {
            let v = r.output.split(separator: "\n").first.map(String.init) ?? ""
            print("  ✓ \(d.name)  \(v)")
        } else {
            print("  ✗ \(d.name) — not found")
            missing.append(d)
        }
    }

    // Simulator runtimes (any Apple platform; needs Xcode).
    let sims = probe("xcrun simctl list runtimes 2>&1 | grep -ci simruntime").output
    if let n = Int(sims), n > 0 {
        print("  ✓ Simulators  \(n) runtime(s)")
    } else {
        print("  ✗ Simulators — none installed  (macon sims install <platform> [version])")
    }
    showSimulators(full: false)

    if missing.isEmpty {
        print("\nAll set. ✅")
    } else if checkOnly {
        print("\nMissing — install with:")
        for d in missing { print("  • \(d.name): \(d.hint)") }
        print("\nRe-run `macon init` (without --check) to auto-install the Homebrew ones.")
    } else {
        print("\nInstalling what I can…")
        for d in missing {
            guard let cmd = d.install else {
                print("  • \(d.name) needs manual setup: \(d.hint)")
                continue
            }
            print("\n⏳ \(d.name) — \(cmd)")
            let code = await Shell.run(cmd, cwd: FileManager.default.currentDirectoryPath) { line in
                print("   \(line)")
            }
            if d.gui {
                print("  → complete \(d.name) in the dialog that opened, then re-run `macon init --check`.")
            } else if code == 0 {
                print("  ✓ \(d.name) installed.")
            } else {
                print("  ✗ \(d.name) failed (exit \(code)) — do it manually: \(d.hint)")
            }
        }
        print("\nDone. Verify with `macon init --check`.")
    }

case "watch" where option("config") != nil:
    // Watch every pipeline from an app export file (macon-export.json). Creds and
    // secrets come from the file if it was exported with them, else from the env.
    let path = option("config")!
    guard let data = FileManager.default.contents(atPath: path),
          let bundle = try? MaconExport.decoded(from: data) else {
        fail("Couldn't read or parse config at \(path).")
    }
    let env = ProcessInfo.processInfo.environment
    let bbEmail = bundle.bitbucketEmail ?? env["BITBUCKET_EMAIL"] ?? ""
    let bbToken = bundle.bitbucketToken ?? env["BITBUCKET_API_TOKEN"] ?? ""
    let ghToken = bundle.githubToken ?? env["GITHUB_TOKEN"] ?? ""

    var configs = bundle.pipelines
    if let only = option("pipeline") {
        configs = configs.filter { $0.name == only || $0.id.uuidString == only }
    }
    guard !configs.isEmpty else { fail("No matching pipelines in \(path).") }
    print("▶ Watching \(configs.count) pipeline(s) from \(path)"
          + (bundle.includesSecrets ? " (with embedded secrets)." : "; secrets from env."))

    let subs = await MainActor.run { () -> [AnyCancellable] in
        var subs: [AnyCancellable] = []
        for cfg in configs {
            let runner = PipelineRunner(config: cfg)
            runner.makeClient = { kind in
                switch kind {
                case .bitbucket: return (bbEmail.isEmpty || bbToken.isEmpty) ? nil
                    : BitbucketClient(email: bbEmail, token: bbToken)
                case .github: return ghToken.isEmpty ? nil : GitHubClient(token: ghToken)
                }
            }
            // Global + this pipeline's secrets from the bundle (empty → env is used).
            let global = bundle.secrets?["global"] ?? [:]
            let own = bundle.secrets?[cfg.id.uuidString] ?? [:]
            let merged = global.merging(own) { _, b in b }
            runner.loadGlobalSecrets = { merged }
            let label = cfg.name
            var printed = 0
            let sub = runner.$log.sink { lines in
                while printed < lines.count { print("[\(label)] \(lines[printed].text)"); printed += 1 }
            }
            subs.append(sub)
            runner.startWatching()
        }
        return subs
    }
    _ = subs
    while true { try? await Task.sleep(for: .seconds(3600)) }

case "watch":
    // Poll a Bitbucket repo and build every new commit (or PR) here — the
    // headless equivalent of the app's "Start Watching". Runs until Ctrl-C.
    let env = ProcessInfo.processInfo.environment
    let providerKind: GitProviderKind = (option("provider")?.lowercased() == "github") ? .github : .bitbucket

    // Build the right client from flags/env for the chosen provider.
    let makeProviderClient: () -> (any GitProvider)?
    switch providerKind {
    case .github:
        let token = option("token") ?? env["GITHUB_TOKEN"] ?? ""
        guard !token.isEmpty else {
            fail("GitHub: set --token (or GITHUB_TOKEN env var) to a PAT with repo access.")
        }
        makeProviderClient = { GitHubClient(token: token) }
    case .bitbucket:
        let email = option("email") ?? env["BITBUCKET_EMAIL"] ?? ""
        let token = option("token") ?? env["BITBUCKET_API_TOKEN"] ?? ""
        guard !email.isEmpty, !token.isEmpty else {
            fail("Bitbucket: set --email and --token (or BITBUCKET_EMAIL / BITBUCKET_API_TOKEN).")
        }
        makeProviderClient = { BitbucketClient(email: email, token: token) }
    }

    guard let ws = option("workspace"), let repo = option("repo") else {
        fail("Need --workspace WS and --repo SLUG.")
    }

    var cfg = PipelineConfig()
    cfg.name = "\(ws)/\(repo)"
    cfg.provider = providerKind
    cfg.workspace = ws
    cfg.repoSlug = repo
    cfg.branch = option("branch") ?? "main"
    cfg.watchMode = flag("prs") ? .pullRequests : .branch
    cfg.prTargetBranch = option("pr-target") ?? ""
    if let n = option("workflow") { cfg.workflow = n }
    if let f = option("file") { cfg.pipelineFile = f }
    if let e = option("every"), let s = Int(e) { cfg.pollSeconds = s }
    cfg.triggerMode = flag("webhook") ? .webhook : .polling
    if let p = option("port"), let n = Int(p) { cfg.webhookPort = n }
    cfg.webhookSecret = option("webhook-secret") ?? env["MACON_WEBHOOK_SECRET"] ?? ""
    if let t = option("timeout"), let m = Int(t) { cfg.buildTimeoutSeconds = m * 60 }
    cfg.postStatus = !flag("no-status")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    cfg.workingDirectory = option("dir") ?? "\(home)/macon-ci/\(repo)"
    cfg.id = stableID("\(providerKind.rawValue):\(ws)/\(repo)@\(cfg.branch):\(cfg.watchMode.rawValue)")

    // Retain the runner + log subscription for the life of the process.
    let keepAlive = await MainActor.run { () -> (PipelineRunner, AnyCancellable) in
        let runner = PipelineRunner(config: cfg)
        runner.makeClient = { _ in makeProviderClient() }
        runner.loadGlobalSecrets = { [:] }   // CLI secrets come from the inherited shell env
        var printed = 0
        let sub = runner.$log.sink { lines in
            while printed < lines.count { print(lines[printed].text); printed += 1 }
        }
        runner.startWatching()
        return (runner, sub)
    }
    _ = keepAlive
    // Sleep forever; the poll loop and builds run on their own tasks.
    while true { try? await Task.sleep(for: .seconds(3600)) }

case "pipelines":
    // Summarize an app export file.
    let path = positional ?? option("config") ?? "macon-export.json"
    guard let data = FileManager.default.contents(atPath: path),
          let bundle = try? MaconExport.decoded(from: data) else {
        fail("Couldn't read or parse \(path).")
    }
    print("\(path) — \(bundle.pipelines.count) pipeline(s)"
          + (bundle.includesSecrets ? ", includes secrets" : ", config only"))
    for cfg in bundle.pipelines {
        let target = cfg.watchMode == .branch ? cfg.branch : "PRs→\(cfg.prTargetBranch.isEmpty ? "any" : cfg.prTargetBranch)"
        print("  • \(cfg.name)  [\(cfg.provider.rawValue)] \(cfg.workspace)/\(cfg.repoSlug) @ \(target) "
              + "(\(cfg.triggerMode.rawValue))")
    }

case "service":
    // Manage a launchd LaunchAgent so a `watch` runs at login and restarts on crash.
    //   macon service install [watch args…] [--label NAME]
    //   macon service uninstall [--label NAME]
    //   macon service status [--label NAME]
    let sub = args.count > 1 && !args[1].hasPrefix("--") ? args[1] : ""
    let label = (option("label") ?? "default")
        .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "-_")))
        .joined()
    let serviceName = "com.macon.\(label.isEmpty ? "default" : label)"
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let plistPath = "\(home)/Library/LaunchAgents/\(serviceName).plist"
    let logDir = "\(home)/Library/Logs/macon"
    let logPath = "\(logDir)/\(label.isEmpty ? "default" : label).log"

    switch sub {
    case "install":
        // Resolve the macon binary via PATH (stable across brew upgrades).
        let onPath = capture("command -v macon", cwd: ".")
        let exe = !onPath.isEmpty ? onPath : (Bundle.main.executablePath ?? CommandLine.arguments[0])

        // Everything after `service install`, minus --label, becomes the watch args.
        var watchArgs = Array(args.dropFirst(2))
        if let li = watchArgs.firstIndex(of: "--label") {
            watchArgs.removeSubrange(li...(li + 1 < watchArgs.count ? li + 1 : li))
        }
        // launchd runs from $HOME, so make --config / --dir absolute.
        for optName in ["--config", "--dir"] {
            if let oi = watchArgs.firstIndex(of: optName), oi + 1 < watchArgs.count,
               !watchArgs[oi + 1].hasPrefix("/") {
                watchArgs[oi + 1] = FileManager.default.currentDirectoryPath + "/" + watchArgs[oi + 1]
            }
        }
        let program = [exe, "watch"] + watchArgs

        // Bake in whatever creds/secrets are set in the current shell.
        let env = ProcessInfo.processInfo.environment
        let passthrough = ["BITBUCKET_EMAIL", "BITBUCKET_API_TOKEN", "GITHUB_TOKEN",
                           "MACON_WEBHOOK_SECRET", "ASC_KEY_ID", "ASC_ISSUER_ID",
                           "ASC_KEY_CONTENT", "SLACK_URL"]
        var envDict: [String: String] = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        for k in passthrough { if let v = env[k], !v.isEmpty { envDict[k] = v } }

        let esc: (String) -> String = {
            $0.replacingOccurrences(of: "&", with: "&amp;")
              .replacingOccurrences(of: "<", with: "&lt;")
              .replacingOccurrences(of: ">", with: "&gt;")
        }
        let progXML = program.map { "      <string>\(esc($0))</string>" }.joined(separator: "\n")
        let envXML = envDict.sorted { $0.key < $1.key }
            .map { "      <key>\($0.key)</key><string>\(esc($0.value))</string>" }.joined(separator: "\n")

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(serviceName)</string>
          <key>ProgramArguments</key>
          <array>
        \(progXML)
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>WorkingDirectory</key><string>\(home)</string>
          <key>StandardOutPath</key><string>\(logPath)</string>
          <key>StandardErrorPath</key><string>\(logPath)</string>
          <key>EnvironmentVariables</key>
          <dict>
        \(envXML)
          </dict>
        </dict>
        </plist>
        """

        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: "\(home)/Library/LaunchAgents", withIntermediateDirectories: true)
        do {
            try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        } catch {
            fail("Couldn't write \(plistPath): \(error.localizedDescription)")
        }
        _ = capture("launchctl unload \(plistPath) 2>/dev/null", cwd: ".")
        let load = probe("launchctl load -w \(plistPath)")
        print("✓ Installed service \(serviceName)")
        print("  runs: \(program.joined(separator: " "))")
        print("  logs: \(logPath)")
        if load.code != 0 { print("  ⚠︎ launchctl load: \(load.output)") }
        print("\nIt now starts at login and restarts on crash. Manage it with:")
        print("  macon service status  --label \(label.isEmpty ? "default" : label)")
        print("  macon service uninstall --label \(label.isEmpty ? "default" : label)")

    case "uninstall":
        _ = capture("launchctl unload \(plistPath) 2>/dev/null", cwd: ".")
        if FileManager.default.fileExists(atPath: plistPath) {
            try? FileManager.default.removeItem(atPath: plistPath)
            print("✓ Removed service \(serviceName).")
        } else {
            print("No service \(serviceName) installed.")
        }

    case "status":
        let r = probe("launchctl list | grep \(serviceName)")
        if r.code == 0 && !r.output.isEmpty {
            print("● \(serviceName) is loaded:")
            print("  \(r.output)")
        } else {
            print("○ \(serviceName) is not loaded.")
        }
        if FileManager.default.fileExists(atPath: plistPath) { print("  plist: \(plistPath)") }
        print("  logs:  \(logPath)")

    default:
        fail("Usage: macon service <install|uninstall|status> [watch args…] [--label NAME]")
    }

case "sims", "simulators", "sim":
    // Inspect / install iOS simulator runtimes and devices for the test matrix.
    let subS = args.count > 1 && !args[1].hasPrefix("--") ? args[1] : "list"
    switch subS {
    case "list":
        print("iOS simulators")
        showSimulators(full: true)

    case "install", "install-os":
        // `macon sims install [platform] [version]` — download a runtime.
        // A bare version (starts with a digit) implies iOS, for convenience.
        var platform = "iOS"
        var version = ""
        let a2 = args.count > 2 ? args[2] : ""
        if let f = a2.first, f.isNumber {
            version = a2
        } else if !a2.isEmpty {
            platform = normalizePlatform(a2)
            version = args.count > 3 ? args[3] : ""
        }
        if platform == "macOS" {
            print("macOS apps build & run natively — there's no simulator runtime to install.")
            break
        }
        let cmd = version.isEmpty
            ? "xcodebuild -downloadPlatform \(platform)"
            : "xcodebuild -downloadPlatform \(platform) -buildVersion \(version)"
        print("⏳ Downloading \(platform) \(version.isEmpty ? "(latest)" : version) simulator runtime — this can take a while…")
        let code = await Shell.run(cmd, cwd: FileManager.default.currentDirectoryPath) { print("   \($0)") }
        if code == 0 {
            print("✓ Done."); showSimulators(full: false)
        } else {
            print("✗ Download failed (exit \(code)).")
            print("  Your Xcode may not support -buildVersion — add the runtime via")
            print("  Xcode ▸ Settings ▸ Components, or run: \(cmd)")
        }

    case "create":
        // `macon sims create "<device type>" <version> [platform]` — make a device.
        guard args.count > 3 else {
            fail("Usage: macon sims create \"<device type>\" <version> [platform]   e.g. \"Apple Watch Series 10 (46mm)\" 11.2 watchOS")
        }
        let device = args[2], version = args[3]
        let platform = args.count > 4 ? normalizePlatform(args[4]) : "iOS"
        // visionOS runtime identifiers use the "xrOS" prefix.
        let prefix = platform.lowercased() == "visionos" ? "xrOS" : platform
        let runtimeID = "com.apple.CoreSimulator.SimRuntime.\(prefix)-" + version.replacingOccurrences(of: ".", with: "-")
        let name = "\(device) (\(version))"
        print("⏳ Creating \(name)…")
        let r = probe("xcrun simctl create \"\(name)\" \"\(device)\" \"\(runtimeID)\"")
        if r.code == 0 {
            print("✓ Created \(name)\(r.output.isEmpty ? "" : " — \(r.output)")")
        } else {
            print("✗ Couldn't create it: \(r.output)")
            print("  Is \(platform) \(version) installed? Run: macon sims install \(platform) \(version)")
        }

    default:
        fail("Usage: macon sims <list | install [platform] [version] | create \"<device>\" <version> [platform]>")
    }

case "help", "--help", "-h":
    print("""
    macon — local CI runner (MaconKit)
    Commands:
      version                      print version
      init [--check]               check the iOS toolchain (Xcode, fastlane, sims…) & install missing
      sims <list|install [platform] [version]|create "<device>" <version> [platform]>
                                   list / install simulator runtimes (iOS, watchOS, tvOS, visionOS)
      lint [path]                  parse and summarize a macon.yml
      pipelines [file.json]        list pipelines in an app export file
      run [--workflow N] [--branch B] [--file macon.yml] [path]
                                   run a workflow once in the given repo dir
      watch --config file.json [--pipeline NAME]
                                   watch pipelines exported from the app
      watch --workspace WS --repo SLUG [options]
                                   build new commits here, until Ctrl-C
        --provider bitbucket|github   git host (default: bitbucket)
                                   GitHub: --token/GITHUB_TOKEN; workspace = owner/org
        --branch B                 branch to watch (default: main)
        --prs [--pr-target B]      watch open PRs instead of a branch
        --webhook [--port N]       push mode: listen for webhooks (default port 8787)
                                   (default is polling — ask the host every --every seconds)
        --webhook-secret S         require this secret (GitHub HMAC, or in the URL path)
        --timeout MINS             cancel a build that runs longer than MINS (0 = no limit)
        --every SECS               poll interval for polling mode (default: 30)
        --workflow N               macon.yml workflow to run (default: auto by trigger)
        --file macon.yml           pipeline file to look for (default: macon.yml)
        --dir PATH                 checkout dir (default: ~/macon-ci/<repo>)
        --no-status                don't post build status back to the host
        --email E --token T        Bitbucket auth (or env BITBUCKET_EMAIL / BITBUCKET_API_TOKEN)
      service <install|uninstall|status> [watch args…] [--label NAME]
                                   run a watch as a launchd service (starts at login, restarts on crash)
    """)

default:
    fail("Unknown command '\(command)'. Try `macon help`.")
}
