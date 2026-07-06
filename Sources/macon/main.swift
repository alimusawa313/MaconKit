import Foundation
import MaconKit

// Tiny zero-dependency CLI over the shared MaconKit core.
// Usage:
//   macon version
//   macon lint [path]     inspect a macon.yml (defaults to ./macon.yml)

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }

switch command {
case "version", "--version", "-v":
    print("macon \(maconVersion)")

case "lint":
    let path = args.count > 1 ? args[1] : "macon.yml"
    guard let pipeline = MaconPipelineLoader.load(atPath: path) else {
        fail("Could not load or parse \(path) (needs Ruby for YAML→JSON).")
    }
    print("✓ \(path) — \(pipeline.name ?? "unnamed")")
    if let env = pipeline.env, !env.isEmpty {
        print("  env: \(env.keys.sorted().joined(separator: ", "))")
    }
    for (name, wf) in (pipeline.workflows ?? [:]).sorted(by: { $0.key < $1.key }) {
        let before = wf.before_run?.joined(separator: ", ") ?? ""
        let after = wf.after_run?.joined(separator: ", ") ?? ""
        print("  workflow \(name)"
              + (before.isEmpty ? "" : "  [before: \(before)]")
              + (after.isEmpty ? "" : "  [after: \(after)]"))
        for step in wf.steps ?? [] {
            print("    • \(step.name)"
                  + (step.run_if != nil ? "  (run_if)" : "")
                  + ((step.always_run ?? false) ? "  (always)" : ""))
        }
    }
    for step in pipeline.steps ?? [] { print("  • \(step.name)") }
    for t in pipeline.triggers ?? [] {
        let match = t.pull_request.map { "PR→\($0)" } ?? t.branch.map { "branch \($0)" } ?? t.tag.map { "tag \($0)" } ?? "?"
        print("  trigger \(match) ⇒ \(t.workflow)")
    }

case "help", "--help", "-h":
    print("""
    macon — local CI runner (MaconKit)
    Commands:
      version        print version
      lint [path]    parse and summarize a macon.yml
    """)

default:
    fail("Unknown command '\(command)'. Try `macon help`.")
}
