//
//  Client.swift
//  macon
//
//  Client-mode commands: talk to a running companion server (the app's or a
//  `macon watch --companion`) over HTTP — status, logs, trigger, cancel.
//  Auth is the same bearer token a paired iPhone uses. Against a local server
//  the CLI pairs itself through the shared on-disk PairingStore; against a
//  remote one (tunnel, EC2 Mac) use `macon pair --host H --code C` once.
//

import Foundation
import CoreGraphics
import ApplicationServices
import MaconKit

// MARK: - Remote server access

enum Remote {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Bare host[:port]; --host wins, else localhost:--port (default 8899).
    static var host: String {
        if let h = option("host") {
            var s = h
            if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
            return s.split(separator: "/").first.map(String.init) ?? s
        }
        return "localhost:\(option("port") ?? "8899")"
    }

    /// Plain HTTP for LAN-ish hosts, HTTPS for real domains (tunnels). Same
    /// heuristic as the companion app; --http / --https force it.
    static var secure: Bool {
        if flag("https") { return true }
        if flag("http") { return false }
        if let h = option("host") {
            if h.hasPrefix("https://") { return true }
            if h.hasPrefix("http://") { return false }
        }
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        if bare == "localhost" || bare.hasSuffix(".local") { return false }
        let parts = bare.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return false }
        if !bare.contains(".") { return false }
        return true
    }

    static var isLocalHost: Bool {
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        return bare == "localhost" || bare == "127.0.0.1"
            || bare == ProcessInfo.processInfo.hostName || bare.hasSuffix(".local")
    }

    private static let tokenAccount = "cli.companion.token"

    /// Resolve a bearer token: --token / MACON_TOKEN / stored / self-pair (local).
    static func token() -> String {
        if let t = option("token") { return t }
        if let t = env["MACON_TOKEN"], !t.isEmpty { return t }
        let stored = Keychain.get(account: tokenAccount)
        if !stored.isEmpty { return stored }
        return selfPair() ?? ""
    }

    /// Against a *local* server, mint + redeem a pairing code through the shared
    /// on-disk store — the server picks the new device up on its next authorize.
    static func selfPair() -> String? {
        guard isLocalHost else { return nil }
        let store = PairingStore()
        let code = store.mintCode(ttl: 60)
        guard let token = store.pair(code: code, device: "macon CLI") else { return nil }
        Keychain.set(token, account: tokenAccount)
        FileHandle.standardError.write(Data("· paired this CLI with the local runner (token stored in Keychain)\n".utf8))
        return token
    }

    static func storeToken(_ t: String) { Keychain.set(t, account: tokenAccount) }

    // MARK: HTTP

    static func url(_ path: String) -> URL? {
        URL(string: "\(secure ? "https" : "http")://\(host)/\(path)")
    }

    static func request(_ path: String, method: String = "GET",
                        body: Data? = nil, authed: Bool = true) async throws -> (Int, Data) {
        guard let url = url(path) else { throw CLIError("Bad host: \(host)") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 15
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authed { req.setValue("Bearer \(token())", forHTTPHeaderField: "Authorization") }
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw CLIError("Can't reach \(host) — \((error as? URLError)?.localizedDescription ?? "connection failed").\n"
                           + "Is the app's companion server on, or a `macon watch --companion` running?")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0

        // Stale local token (server re-paired / store reset) → re-pair once.
        if code == 401, authed, isLocalHost, option("token") == nil, env["MACON_TOKEN"] == nil {
            Keychain.set("", account: tokenAccount)
            guard let fresh = selfPair() else { return (code, data) }
            var retry = req
            retry.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            let (d2, r2) = try await URLSession.shared.data(for: retry)
            return ((r2 as? HTTPURLResponse)?.statusCode ?? 0, d2)
        }
        return (code, data)
    }

    static func getJSON<T: Decodable>(_ path: String) async throws -> T {
        let (code, data) = try await request(path)
        guard code == 200 else { throw CLIError(httpHint(code)) }
        return try CompanionJSON.decoder.decode(T.self, from: data)
    }

    static func httpHint(_ code: Int) -> String {
        switch code {
        case 0:   return "No server at \(host). Is the app running with the companion on, or `macon watch --companion`?"
        case 401: return "Not authorized. Pair first: macon pair --host \(host) --code <CODE> (code from the Mac)."
        case 404: return "The server at \(host) doesn't offer that (older version?)."
        default:  return "Server returned HTTP \(code)."
        }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

// MARK: - Resolving names

/// Find a pipeline by (case-insensitive) name, id, or unique prefix of either.
func resolvePipeline(_ needle: String, in list: [CompanionPipelineDTO]) -> CompanionPipelineDTO? {
    let n = needle.lowercased()
    if let exact = list.first(where: { $0.name.lowercased() == n || $0.id.lowercased() == n }) { return exact }
    let hits = list.filter { $0.name.lowercased().hasPrefix(n) || $0.id.lowercased().hasPrefix(n) }
    return hits.count == 1 ? hits.first : nil
}

/// The most interesting build for a pipeline id: the live one, else the newest.
func latestBuild(forPipeline pid: String, in builds: [CompanionBuildDTO]) -> CompanionBuildDTO? {
    let mine = builds.filter { $0.id.hasPrefix("\(pid)~") }
    return mine.first { $0.id.hasSuffix("~live") } ?? mine.first
}

// MARK: - Output helpers

func statusGlyph(_ s: String) -> String {
    switch s {
    case "running": return "◐"
    case "queued":  return "○"
    case "passed":  return "●"
    case "failed":  return "✗"
    default:        return "-"
    }
}

func printBuildRow(_ b: CompanionBuildDTO) {
    var extra = ""
    if let s = b.startedAt {
        let end = b.finishedAt ?? Date()
        let secs = Int(end.timeIntervalSince(s))
        extra = "  \(secs >= 60 ? "\(secs / 60)m \(secs % 60)s" : "\(secs)s")"
    }
    if let step = b.currentStep, b.status == "running" { extra += "  ▸ \(step)" }
    print("  \(statusGlyph(b.status)) \(b.commit)  \(b.repo) @ \(b.branch)  \(b.status)\(extra)")
}

/// Combined `macon status` payload for --json.
struct StatusOut: Codable {
    var runnerName: String
    var managed: Bool
    var pipelines: [CompanionPipelineDTO]
    var builds: [CompanionBuildDTO]
}

func printJSON<T: Encodable>(_ value: T) {
    let enc = CompanionJSON.encoder
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) { print(s) }
}

// MARK: - Log tailing

/// Print a build's log lines after `seq`; returns the highest seq seen.
func fetchLogs(buildID: String, after: Int) async throws -> Int {
    let (code, data) = try await Remote.request("builds/\(buildID)/logs?after=\(after)")
    guard code == 200 else { throw CLIError(Remote.httpHint(code)) }
    let lines = (try? CompanionJSON.decoder.decode([CompanionLogDTO].self, from: data)) ?? []
    var last = after
    for l in lines { print(l.text); last = max(last, l.seq) }
    return last
}

/// Tail a build until it finishes. Returns the final status string.
func followBuild(_ buildID: String) async throws -> String {
    var seq = -1
    var pid: String { String(buildID.split(separator: "~").first ?? "") }
    while true {
        seq = try await fetchLogs(buildID: buildID, after: seq)
        // A build is over when it's no longer queued/running (or, for the live
        // id, when the live entry disappears — then the newest run has the verdict).
        let builds: CompanionBuildsDTO = try await Remote.getJSON("builds")
        if let b = builds.builds.first(where: { $0.id == buildID }) {
            if b.status != "running" && b.status != "queued" { return b.status }
        } else if buildID.hasSuffix("~live") {
            let done = builds.builds.first { $0.id.hasPrefix("\(pid)~") && !$0.id.hasSuffix("~live") }
            return done?.status ?? "unknown"
        } else {
            return "unknown"
        }
        try? await Task.sleep(for: .seconds(2))
    }
}

// MARK: - Doctor extras

/// Free/total disk space on the home volume.
func diskSpace() -> (freeGB: Double, totalGB: Double)? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: home),
          let free = attrs[.systemFreeSize] as? Int64,
          let total = attrs[.systemSize] as? Int64 else { return nil }
    return (Double(free) / 1_073_741_824, Double(total) / 1_073_741_824)
}

/// TCC states for *this process* (the terminal). The desktop app holds its own
/// grants — these matter for headless setups where the CLI does the serving.
func tccChecks() -> [(name: String, ok: Bool, detail: String)] {
    let screen = CGPreflightScreenCaptureAccess()
    let ax = AXIsProcessTrusted()
    return [
        ("Screen Recording (this terminal)", screen,
         screen ? "granted" : "needed only for screen streaming — System Settings → Privacy → Screen Recording"),
        ("Accessibility (this terminal)", ax,
         ax ? "granted" : "needed only for remote control — System Settings → Privacy → Accessibility"),
    ]
}

// MARK: - Portable config

/// A starter macon-export.json with one commented-by-example pipeline.
func configTemplate() -> MaconExport {
    var cfg = PipelineConfig()
    cfg.name = "My App"
    cfg.provider = .github
    cfg.workspace = "your-org"
    cfg.repoSlug = "your-repo"
    cfg.branch = "main"
    cfg.buildCommand = "xcodebuild -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test"
    cfg.workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path + "/macon-ci/your-repo"
    return MaconExport(pipelines: [cfg])
}

struct ConfigIssue: Codable { let pipeline: String; let level: String; let message: String }

/// Validate an export bundle; returns issues ("error" blocks, "warning" doesn't).
func validateExport(_ bundle: MaconExport) -> [ConfigIssue] {
    var issues: [ConfigIssue] = []
    let env = ProcessInfo.processInfo.environment
    func err(_ p: String, _ m: String) { issues.append(ConfigIssue(pipeline: p, level: "error", message: m)) }
    func warn(_ p: String, _ m: String) { issues.append(ConfigIssue(pipeline: p, level: "warning", message: m)) }

    if bundle.pipelines.isEmpty { err("-", "No pipelines in the file.") }

    var webhookPorts: [Int: String] = [:]
    for cfg in bundle.pipelines {
        let p = cfg.name
        if cfg.workspace.isEmpty { err(p, "workspace is empty") }
        if cfg.repoSlug.isEmpty { err(p, "repo_slug is empty") }
        if cfg.watchMode == .branch && cfg.branch.isEmpty { err(p, "branch is empty") }
        if cfg.workingDirectory.isEmpty { warn(p, "working_directory is empty (watch will fail to clone)") }
        if cfg.pipelineFile.isEmpty && cfg.buildCommand.isEmpty { err(p, "no pipeline file and no build command") }
        if cfg.triggerMode == .webhook {
            if let other = webhookPorts[cfg.webhookPort] {
                err(p, "webhook port \(cfg.webhookPort) already used by “\(other)”")
            }
            webhookPorts[cfg.webhookPort] = p
        }
        switch cfg.provider {
        case .bitbucket:
            let email = bundle.bitbucketEmail ?? env["BITBUCKET_EMAIL"] ?? ""
            let token = bundle.bitbucketToken ?? env["BITBUCKET_API_TOKEN"] ?? ""
            if email.isEmpty || token.isEmpty {
                warn(p, "Bitbucket credentials not in file or env (BITBUCKET_EMAIL / BITBUCKET_API_TOKEN)")
            }
        case .github:
            if (bundle.githubToken ?? env["GITHUB_TOKEN"] ?? "").isEmpty {
                warn(p, "GitHub token not in file or env (GITHUB_TOKEN)")
            }
        }
        for key in cfg.secretKeys {
            let inBundle = bundle.secrets?["global"]?[key] != nil || bundle.secrets?[cfg.id.uuidString]?[key] != nil
            if !inBundle && (env[key] ?? "").isEmpty {
                warn(p, "secret \(key) not in file or env")
            }
        }
    }
    return issues
}

// MARK: - Shell completions

let zshCompletion = #"""
#compdef macon
# macon zsh completion — install: macon completions zsh > $(brew --prefix)/share/zsh/site-functions/_macon
_macon() {
  local -a commands
  commands=(
    'version:print version'
    'doctor:check toolchain, permissions, disk'
    'init:check & install the iOS toolchain'
    'status:builds + pipelines on a running server'
    'logs:print/tail a build log'
    'trigger:run a pipeline now'
    'cancel:cancel a running build'
    'pair:pair this CLI with a remote runner'
    'run:run a workflow here, once'
    'lint:parse and summarize a macon.yml'
    'validate:validate a macon.yml or export file'
    'config:portable config (init | validate)'
    'pipelines:list pipelines in an export file'
    'watch:watch a repo and build new commits'
    'sims:list/install simulator runtimes'
    'companion:manage paired companion devices'
    'service:run a watch as a launchd service'
    'install-service:alias for service install'
    'completions:print shell completions'
    'help:show help'
  )
  if (( CURRENT == 2 )); then
    _describe 'command' commands
    return
  fi
  case $words[2] in
    status|logs|trigger|cancel|pair)
      _arguments '--host[host:port or tunnel domain]:host:' '--token[bearer token]:token:' \
                 '--json[JSON output]' '--follow[tail until finished]' '--code[pairing code]:code:'
      ;;
    watch)
      _arguments '--workspace:ws:' '--repo:slug:' '--branch:branch:' '--provider:(bitbucket github)' \
                 '--prs' '--webhook' '--companion' '--config:file:_files' '--every:secs:'
      ;;
    config) _values 'sub' 'init' 'validate' ;;
    sims) _values 'sub' 'list' 'install' 'create' ;;
    service) _values 'sub' 'install' 'uninstall' 'status' ;;
    companion) _values 'sub' 'devices' 'revoke' 'revoke-all' ;;
    completions) _values 'shell' 'zsh' 'bash' ;;
    *) _files ;;
  esac
}
_macon "$@"
"""#

let bashCompletion = #"""
# macon bash completion — install: macon completions bash > /usr/local/etc/bash_completion.d/macon
_macon() {
  local cur prev commands
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  commands="version doctor init status logs trigger cancel pair run lint validate config pipelines watch sims companion service install-service completions help"
  if [ $COMP_CWORD -eq 1 ]; then
    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    return
  fi
  case "${COMP_WORDS[1]}" in
    config) COMPREPLY=( $(compgen -W "init validate" -- "$cur") ) ;;
    sims) COMPREPLY=( $(compgen -W "list install create" -- "$cur") ) ;;
    service) COMPREPLY=( $(compgen -W "install uninstall status" -- "$cur") ) ;;
    companion) COMPREPLY=( $(compgen -W "devices revoke revoke-all" -- "$cur") ) ;;
    completions) COMPREPLY=( $(compgen -W "zsh bash" -- "$cur") ) ;;
    *) COMPREPLY=( $(compgen -W "--host --token --json --follow --workspace --repo --branch --companion" -- "$cur") ) ;;
  esac
}
complete -F _macon macon
"""#
