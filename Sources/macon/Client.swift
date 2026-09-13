//
//  Client.swift
//  macon
//
//  Client-mode commands: talk to a running companion server (the app's or a
//  `macon watch --companion`) over HTTPS — status, logs, trigger, cancel.
//  Auth is the same bearer token a paired iPhone uses. Against a local server
//  the CLI pairs itself through the shared on-disk PairingStore; against a
//  remote one (tunnel, EC2 Mac) use `macon pair --host H --code C` once.
//
//  Transport: a tunnel domain has a real certificate and is checked against the
//  public CA set. A Mac on the local network presents its own self-signed one
//  (LANIdentity), so there the certificate is pinned instead: exactly the one we
//  were told to expect, or nothing. On this same Mac the pin is read straight
//  out of the identity file; for another Mac `macon pair` records it, or pass
//  --pin. Otherwise a token would ride the local network in the clear, which is
//  the whole point of the LAN listener speaking TLS.
//

import Foundation
import CoreGraphics
import ApplicationServices
import CryptoKit
import Security
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

    /// HTTPS everywhere now: the companion port speaks TLS on every interface.
    /// --http is kept for talking to a Mac from before that change.
    static var secure: Bool {
        if flag("https") { return true }
        if flag("http") { return false }
        if let h = option("host"), h.hasPrefix("http://") { return false }
        return true
    }

    /// Switch this process to the cleartext loopback listener (port + 1,
    /// 127.0.0.1 only, what cloudflared talks to) for the rest of its run.
    /// For a hook on the same Mac when the TLS port is not being served.
    /// Returns false when already switched.
    nonisolated(unsafe) private static var onLoopback = false
    static func loopbackFallback() -> Bool {
        guard !onLoopback else { return false }
        onLoopback = true
        let port = UInt16(host.split(separator: ":").last.map(String.init) ?? "") ?? 8899
        args += ["--host", "http://127.0.0.1:\(CompanionServer.loopbackPort(for: port))"]
        return true
    }

    static var isLocalHost: Bool {
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        return bare == "localhost" || bare == "127.0.0.1"
            || bare == ProcessInfo.processInfo.hostName || bare.hasSuffix(".local")
    }

    /// A Mac on the local network (or this one) rather than a tunnel domain.
    /// Those present a self-signed certificate, so they are pinned; a real
    /// domain is checked the ordinary way.
    static var isLANish: Bool {
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        if bare == "localhost" || bare == "127.0.0.1" || bare.hasSuffix(".local") { return true }
        let parts = bare.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return true }
        return !bare.contains(".")
    }

    // MARK: LAN certificate pinning

    private static func pinAccount(_ h: String) -> String { "cli.pin.\(h.lowercased())" }

    /// The certificate we expect on the LAN: --pin, else one recorded by a
    /// previous `macon pair`, else (on this same Mac) the identity file itself.
    static func expectedPin() -> String? {
        guard isLANish else { return nil }
        if let pin = option("pin") { return pin }
        let stored = Keychain.get(account: pinAccount(host))
        if !stored.isEmpty { return stored }
        if isLocalHost { return LANIdentity.pin() }
        return nil
    }

    static func storePin(_ pin: String) { Keychain.set(pin, account: pinAccount(host)) }

    /// Accepts the LAN certificate only if it is byte-for-byte the expected one.
    /// There is no CA to fall back on and the address is an IP or a .local name,
    /// so a pin is the only thing that means anything here.
    final class PinnedTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
        let expected: String?
        /// First sight: accept whatever is offered and remember it, so
        /// `macon pair` can record a pin and check it against what the pairing
        /// response says it should be.
        let trustOnFirstUse: Bool
        private(set) var observed: String?
        private(set) var mismatched = false

        init(expected: String?, trustOnFirstUse: Bool) {
            self.expected = expected
            self.trustOnFirstUse = trustOnFirstUse
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil); return
            }
            // A tunnel domain has a real chain: let the system judge it.
            guard Remote.isLANish else { completionHandler(.performDefaultHandling, nil); return }
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            let seen = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)).base64EncodedString()
            observed = seen
            if let expected {
                if seen == expected { completionHandler(.useCredential, URLCredential(trust: trust)) }
                else { mismatched = true; completionHandler(.cancelAuthenticationChallenge, nil) }
            } else if trustOnFirstUse {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    static func makeSession(trustOnFirstUse: Bool) -> (session: URLSession, trust: PinnedTrust) {
        let delegate = PinnedTrust(expected: expectedPin(), trustOnFirstUse: trustOnFirstUse)
        return (URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil), delegate)
    }

    /// One session for the run. URLSession.shared cannot carry a delegate, and
    /// the delegate is where the pin is checked.
    private static let standard: (session: URLSession, trust: PinnedTrust) = makeSession(trustOnFirstUse: false)

    private static let tokenAccount = "cli.companion.token"

    /// A hook runs inside an agent with nobody there to answer a Keychain
    /// prompt, so it keeps its token in a file beside the pairings instead
    /// (same owner, same folder, 0600). Set by `macon hook`.
    nonisolated(unsafe) static var tokenFromFileOnly = false

    private static var tokenFileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MacON/companion/cli-token")
    }

    private static func readTokenFile() -> String {
        (try? String(contentsOf: tokenFileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func writeTokenFile(_ token: String) {
        let url = tokenFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? token.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Resolve a bearer token: --token / MACON_TOKEN / stored / self-pair (local).
    static func token() -> String {
        if let t = option("token") { return t }
        if let t = env["MACON_TOKEN"], !t.isEmpty { return t }
        if tokenFromFileOnly {
            let file = readTokenFile()
            if !file.isEmpty { return file }
            return selfPair() ?? ""
        }
        let stored = Keychain.get(account: tokenAccount)
        if !stored.isEmpty { return stored }
        let file = readTokenFile()
        if !file.isEmpty { return file }
        return selfPair() ?? ""
    }

    /// Against a *local* server, mint + redeem a pairing code through the shared
    /// on-disk store — the server picks the new device up on its next authorize.
    static func selfPair() -> String? {
        guard isLocalHost else { return nil }
        let store = PairingStore()
        let code = store.mintCode(ttl: 60)
        let name = tokenFromFileOnly ? "MacOn hooks" : "macon CLI"
        guard let token = store.pair(code: code, device: name) else { return nil }
        writeTokenFile(token)
        if !tokenFromFileOnly {
            Keychain.set(token, account: tokenAccount)
            FileHandle.standardError.write(Data("· paired this CLI with the local runner (token stored in Keychain)\n".utf8))
        }
        return token
    }

    static func storeToken(_ t: String) { Keychain.set(t, account: tokenAccount) }

    // MARK: HTTP

    static func url(_ path: String) -> URL? {
        URL(string: "\(secure ? "https" : "http")://\(host)/\(path)")
    }

    static func request(_ path: String, method: String = "GET",
                        body: Data? = nil, authed: Bool = true,
                        using: (session: URLSession, trust: PinnedTrust)? = nil) async throws -> (Int, Data) {
        guard let url = url(path) else { throw CLIError("Bad host: \(host)") }
        let transport = using ?? standard
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 15
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authed { req.setValue("Bearer \(token())", forHTTPHeaderField: "Authorization") }
        // The companion server answers with Connection: close, so a burst of
        // calls (an assistant working through several tools) can meet a socket
        // that is already going away. One retry turns that from a failure into
        // a pause; a real outage still fails, just a moment later.
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await transport.session.data(for: req)
        } catch {
            do {
                try await Task.sleep(for: .milliseconds(250))
                (data, resp) = try await transport.session.data(for: req)
            } catch {
                throw CLIError(reachHint(error, trust: transport.trust))
            }
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0

        // Stale local token (server re-paired / store reset) → re-pair once.
        if code == 401, authed, isLocalHost, option("token") == nil, env["MACON_TOKEN"] == nil {
            if !tokenFromFileOnly { Keychain.set("", account: tokenAccount) }
            try? FileManager.default.removeItem(at: tokenFileURL)
            guard let fresh = selfPair() else { return (code, data) }
            var retry = req
            retry.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            let (d2, r2) = try await transport.session.data(for: retry)
            return ((r2 as? HTTPURLResponse)?.statusCode ?? 0, d2)
        }
        return (code, data)
    }

    static func getJSON<T: Decodable>(_ path: String) async throws -> T {
        let (code, data) = try await request(path)
        guard code == 200 else { throw CLIError(httpHint(code)) }
        return try CompanionJSON.decoder.decode(T.self, from: data)
    }

    /// Why we could not connect, said usefully. A refused pin looks exactly like
    /// an unreachable host from the outside, and the fix is completely different.
    private static func reachHint(_ error: Error, trust: PinnedTrust) -> String {
        if trust.mismatched {
            return """
            The Mac at \(host) presented a different certificate than the one on record.
            Expected \(trust.expected ?? "?")
            Got      \(trust.observed ?? "?")
            Either its certificate was regenerated (pair again, or pass --pin with the new
            value from Settings → Companion), or something is sitting between you and it.
            """
        }
        if isLANish, expectedPin() == nil {
            return """
            Can't verify \(host): a Mac on the local network serves the companion over TLS
            with its own certificate, and this CLI has no record of which one to expect.
            Run: macon pair --host \(host) --code <CODE>   (records it), or pass --pin <value>.
            """
        }
        return "Can't reach \(host), \((error as? URLError)?.localizedDescription ?? "connection failed").\n"
            + "Is the app's companion server on, or a `macon watch --companion` running?"
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
         screen ? "granted" : "needed only for screen streaming, System Settings → Privacy → Screen Recording"),
        ("Accessibility (this terminal)", ax,
         ax ? "granted" : "needed only for remote control, System Settings → Privacy → Accessibility"),
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
# macon zsh completion, install: macon completions zsh > $(brew --prefix)/share/zsh/site-functions/_macon
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
# macon bash completion, install: macon completions bash > /usr/local/etc/bash_completion.d/macon
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
