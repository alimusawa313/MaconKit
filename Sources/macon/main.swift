import Foundation
import MaconKit

// Tiny zero-dependency CLI over the shared MaconKit core.
// Usage:
//   macon version
//   macon lint [path]                       inspect a macon.yml
//   macon run [--workflow NAME] [--branch B] [path]   run a workflow here

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }

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

case "help", "--help", "-h":
    print("""
    macon — local CI runner (MaconKit)
    Commands:
      version                      print version
      lint [path]                  parse and summarize a macon.yml
      run [--workflow N] [--branch B] [--file macon.yml] [path]
                                   run a workflow in the given repo dir
    """)

default:
    fail("Unknown command '\(command)'. Try `macon help`.")
}
