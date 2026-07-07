import Foundation
import Combine
import MaconKit

// Tiny zero-dependency CLI over the shared MaconKit core.
// Usage:
//   macon version
//   macon lint [path]                       inspect a macon.yml
//   macon run [--workflow NAME] [--branch B] [path]   run a workflow here
//   macon watch --workspace WS --repo SLUG  poll Bitbucket & build here

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

/// Parse `--flag value` options and a trailing positional argument.
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}
var positional: String? {
    // last arg that isn't a flag or a flag's value
    var skip = Set<Int>()
    for (i, a) in args.enumerated() where a.hasPrefix("--") { skip.insert(i); skip.insert(i + 1) }
    return args.enumerated().dropFirst()
        .last(where: { !skip.contains($0.offset) && !$0.element.hasPrefix("--") })?.element
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

case "watch":
    // Poll a Bitbucket repo and build every new commit (or PR) here — the
    // headless equivalent of the app's "Start Watching". Runs until Ctrl-C.
    let env = ProcessInfo.processInfo.environment
    let email = option("email") ?? env["BITBUCKET_EMAIL"] ?? ""
    let token = option("token") ?? env["BITBUCKET_API_TOKEN"] ?? ""
    guard !email.isEmpty, !token.isEmpty else {
        fail("Set --email and --token (or BITBUCKET_EMAIL / BITBUCKET_API_TOKEN env vars).")
    }
    guard let ws = option("workspace"), let repo = option("repo") else {
        fail("Need --workspace WS and --repo SLUG.")
    }

    var cfg = PipelineConfig()
    cfg.name = "\(ws)/\(repo)"
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
    cfg.postStatus = !flag("no-status")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    cfg.workingDirectory = option("dir") ?? "\(home)/macon-ci/\(repo)"
    cfg.id = stableID("\(ws)/\(repo)@\(cfg.branch):\(cfg.watchMode.rawValue)")

    // Retain the runner + log subscription for the life of the process.
    let keepAlive = await MainActor.run { () -> (PipelineRunner, AnyCancellable) in
        let runner = PipelineRunner(config: cfg)
        runner.makeClient = { BitbucketClient(email: email, token: token) }
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

case "help", "--help", "-h":
    print("""
    macon — local CI runner (MaconKit)
    Commands:
      version                      print version
      lint [path]                  parse and summarize a macon.yml
      run [--workflow N] [--branch B] [--file macon.yml] [path]
                                   run a workflow once in the given repo dir
      watch --workspace WS --repo SLUG [options]
                                   build new commits here, until Ctrl-C
        --branch B                 branch to watch (default: main)
        --prs [--pr-target B]      watch open PRs instead of a branch
        --webhook [--port N]       push mode: listen for Bitbucket webhooks (default port 8787)
                                   (default is polling — ask Bitbucket every --every seconds)
        --every SECS               poll interval for polling mode (default: 30)
        --workflow N               macon.yml workflow to run (default: auto by trigger)
        --file macon.yml           pipeline file to look for (default: macon.yml)
        --dir PATH                 checkout dir (default: ~/macon-ci/<repo>)
        --no-status                don't post build status back to Bitbucket
        --email E --token T        Bitbucket auth (or env BITBUCKET_EMAIL / BITBUCKET_API_TOKEN)
    """)

default:
    fail("Unknown command '\(command)'. Try `macon help`.")
}
