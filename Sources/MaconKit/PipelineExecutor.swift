//
//  PipelineExecutor.swift
//  MaconKit
//
//  Resolves and runs a macon.yml workflow with Bitrise-like semantics
//  (before/after composition, run_if conditions, always_run, fail-fast).
//  Shared by the GUI runner and the `macon` CLI.
//

import Foundation

public enum PipelineExecutor {

    public struct Options: Sendable {
        public var workingDirectory: String
        /// Explicit workflow to run; nil/empty = auto-pick via `triggers`.
        public var workflowName: String?
        /// Branch name for branch-trigger matching (and default env).
        public var branch: String?
        /// If set, this is a PR build: match `pull_request` triggers on this dest branch.
        public var pullRequestDestBranch: String?
        /// External env (built-ins, secrets, credentials) applied over pipeline/workflow env.
        public var env: [String: String]
        /// Cooperative cancellation, checked before each step.
        public var shouldCancel: @Sendable () -> Bool
        /// Receives each spawned step process (for cancellation).
        public var onProcess: @Sendable (Process) -> Void

        public init(workingDirectory: String,
                    workflowName: String? = nil,
                    branch: String? = nil,
                    pullRequestDestBranch: String? = nil,
                    env: [String: String] = [:],
                    shouldCancel: @escaping @Sendable () -> Bool = { false },
                    onProcess: @escaping @Sendable (Process) -> Void = { _ in }) {
            self.workingDirectory = workingDirectory
            self.workflowName = workflowName
            self.branch = branch
            self.pullRequestDestBranch = pullRequestDestBranch
            self.env = env
            self.shouldCancel = shouldCancel
            self.onProcess = onProcess
        }
    }

    struct ResolvedStep { let step: MaconStep; let env: [String: String] }

    /// Run the pipeline, streaming output via `onLine`. Returns the exit code (0 = success).
    public static func run(_ pipeline: MaconPipeline, options: Options,
                           onLine: @escaping @Sendable (String) -> Void) async -> Int32 {
        let appEnv = pipeline.env ?? [:]
        var resolved: [ResolvedStep] = []
        var workflowName = "default"

        if let name = chooseWorkflow(pipeline, options: options) {
            workflowName = name
            onLine("▶︎ Workflow: \(name)")
            var visiting = Set<String>()
            expand(name, pipeline, appEnv: appEnv, visiting: &visiting, into: &resolved, onLine: onLine)
            if resolved.isEmpty { onLine("✗ Workflow “\(name)” has no steps."); return 1 }
        } else if let steps = pipeline.steps, !steps.isEmpty {
            resolved = steps.map { ResolvedStep(step: $0, env: appEnv) }
        } else {
            onLine("✗ No workflow matched and no top-level steps."); return 1
        }

        var failed = false
        var firstFailCode: Int32 = 0

        for r in resolved {
            if options.shouldCancel() { return firstFailCode == 0 ? 1 : firstFailCode }
            onLine("--- Step: \(r.step.name) ---")

            if failed && !(r.step.always_run ?? false) {
                onLine("↷ Skipped (a previous step failed)."); continue
            }
            var env = r.env
            for (k, v) in options.env { env[k] = v }   // external env (secrets) wins
            env["MACON_WORKFLOW"] = workflowName

            if let cond = r.step.run_if?.trimmingCharacters(in: .whitespacesAndNewlines), !cond.isEmpty {
                let c = await Shell.run(cond, cwd: options.workingDirectory, extraEnv: env,
                                        onProcess: options.onProcess, onLine: onLine)
                if c != 0 { onLine("↷ Skipped (run_if not met)."); continue }
            }

            let code = await Shell.run(r.step.script, cwd: options.workingDirectory, extraEnv: env,
                                       onProcess: options.onProcess, onLine: onLine)
            if code != 0 {
                onLine("✗ Step “\(r.step.name)” failed (exit \(code)).")
                if !failed { failed = true; firstFailCode = code }
            }
        }
        return failed ? firstFailCode : 0
    }

    /// Pick the workflow: explicit override, else match branch/PR to triggers, else default/single.
    static func chooseWorkflow(_ pipeline: MaconPipeline, options: Options) -> String? {
        if let explicit = options.workflowName?.trimmingCharacters(in: .whitespaces), !explicit.isEmpty {
            return explicit
        }
        if let triggers = pipeline.triggers {
            if let dest = options.pullRequestDestBranch {
                for t in triggers where t.pull_request != nil {
                    if t.pull_request == "*" || globMatch(t.pull_request!, dest) { return t.workflow }
                }
            } else if let branch = options.branch {
                for t in triggers { if let b = t.branch, globMatch(b, branch) { return t.workflow } }
            }
        }
        if pipeline.workflows?["default"] != nil { return "default" }
        if let wfs = pipeline.workflows, wfs.count == 1 { return wfs.keys.first }
        return nil
    }

    /// Expand a workflow: before_run → own steps → after_run. Guards cycles/double-runs.
    static func expand(_ name: String, _ pipeline: MaconPipeline,
                       appEnv: [String: String], visiting: inout Set<String>,
                       into out: inout [ResolvedStep], onLine: @escaping @Sendable (String) -> Void) {
        guard !visiting.contains(name) else { return }
        guard let wf = pipeline.workflows?[name] else {
            onLine("⚠︎ Referenced workflow “\(name)” not found."); return
        }
        visiting.insert(name)
        for b in wf.before_run ?? [] {
            expand(b, pipeline, appEnv: appEnv, visiting: &visiting, into: &out, onLine: onLine)
        }
        var env = appEnv
        for (k, v) in wf.env ?? [:] { env[k] = v }
        for s in wf.steps ?? [] { out.append(ResolvedStep(step: s, env: env)) }
        for a in wf.after_run ?? [] {
            expand(a, pipeline, appEnv: appEnv, visiting: &visiting, into: &out, onLine: onLine)
        }
    }

    static func globMatch(_ pattern: String, _ value: String) -> Bool {
        let rx = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return value.range(of: "^\(rx)$", options: .regularExpression) != nil
    }
}
