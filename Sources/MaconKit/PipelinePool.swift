//
//  PipelinePool.swift
//  MacON
//
//  Manages local CI pipelines + the shared Bitbucket account.
//

import Foundation
import Combine

@MainActor
public final class PipelinePool: ObservableObject {

    @Published public private(set) var pipelines: [PipelineRunner] = []

    // Shared Bitbucket account (email in UserDefaults, token in Keychain).
    @Published public var email: String {
        didSet { defaults.set(email, forKey: Keys.email) }
    }
    @Published public var apiToken: String {
        didSet { Keychain.set(apiToken, account: "apiToken") }
    }

    /// GitHub Personal Access Token (for pipelines whose provider is GitHub).
    @Published public var githubToken: String {
        didSet { Keychain.set(githubToken, account: "githubToken") }
    }

    /// Names of global secret env vars (shared by every pipeline). Values live in
    /// the Keychain; only names are persisted here.
    @Published public private(set) var globalSecretKeys: [String] = []

    private let defaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()
    private enum Keys {
        static let pipelines = "pipelines.configs"
        static let email = "pipelines.email"
        static let globalSecretKeys = "pipelines.globalSecretKeys"
    }

    public init() {
        email = defaults.string(forKey: Keys.email) ?? ""
        apiToken = Keychain.get(account: "apiToken")
        githubToken = Keychain.get(account: "githubToken")
        globalSecretKeys = defaults.stringArray(forKey: Keys.globalSecretKeys) ?? []
        for cfg in Self.load() {
            add(runnerFor: cfg)
        }
    }

    // MARK: - Global secrets

    public static func globalSecretAccount(_ key: String) -> String { "secret:global:\(key)" }

    /// Current global secret values from the Keychain.
    public func globalSecrets() -> [String: String] {
        var out: [String: String] = [:]
        for key in globalSecretKeys {
            let v = Keychain.get(account: Self.globalSecretAccount(key))
            if !v.isEmpty { out[key] = v }
        }
        return out
    }

    /// Replace the global secrets (writes values to Keychain, prunes removed keys).
    public func setGlobalSecrets(_ rows: [(key: String, value: String)]) {
        var keys: [String] = []
        for row in rows {
            let k = row.key.trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { continue }
            Keychain.set(row.value, account: Self.globalSecretAccount(k))
            keys.append(k)
        }
        for old in globalSecretKeys where !keys.contains(old) {
            Keychain.set("", account: Self.globalSecretAccount(old))
        }
        globalSecretKeys = keys
        defaults.set(keys, forKey: Keys.globalSecretKeys)
    }

    public var credentials: BitbucketCredentials { .init(email: email, apiToken: apiToken) }

    /// Whether credentials are set for a given provider.
    public func hasCredentials(for kind: GitProviderKind) -> Bool {
        switch kind {
        case .bitbucket: return credentials.isComplete
        case .github:    return !githubToken.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// A client for the given provider, or nil if its credentials aren't set.
    public func makeClient(for kind: GitProviderKind) -> (any GitProvider)? {
        switch kind {
        case .bitbucket:
            guard credentials.isComplete else { return nil }
            return BitbucketClient(email: email, token: apiToken)
        case .github:
            let t = githubToken.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            return GitHubClient(token: t)
        }
    }

    /// Bitbucket-only convenience kept for existing callers/UI.
    public func makeClient() -> (any GitProvider)? { makeClient(for: .bitbucket) }

    // MARK: - Mutating

    @discardableResult
    public func addPipeline() -> PipelineRunner {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var cfg = PipelineConfig()
        cfg.name = "Pipeline \(pipelines.count + 1)"
        cfg.workingDirectory = "\(home)/macon-ci/\(cfg.id.uuidString.prefix(8))"
        let runner = add(runnerFor: cfg)
        persist()
        return runner
    }

    @discardableResult
    private func add(runnerFor cfg: PipelineConfig) -> PipelineRunner {
        let runner = PipelineRunner(config: cfg)
        runner.makeClient = { [weak self] kind in self?.makeClient(for: kind) }
        runner.loadGlobalSecrets = { [weak self] in self?.globalSecrets() ?? [:] }
        // Forward child changes so the menu bar / aggregate counts stay in sync.
        runner.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        pipelines.append(runner)
        return runner
    }

    public func remove(_ runner: PipelineRunner) {
        runner.stopWatching()
        pipelines.removeAll { $0.id == runner.id }
        persist()
    }

    public func commitEdits() { persist() }

    public func startAll() { for p in pipelines { p.startWatching() } }
    public func stopAll()  { for p in pipelines where p.isWatching { p.stopWatching() } }

    public var watchingCount: Int { pipelines.filter(\.isWatching).count }

    // MARK: - Persistence

    private func persist() {
        let configs = pipelines.map(\.config)
        if let data = try? JSONEncoder().encode(configs) {
            defaults.set(data, forKey: Keys.pipelines)
        }
    }
    private static func load() -> [PipelineConfig] {
        guard let data = UserDefaults.standard.data(forKey: Keys.pipelines),
              let list = try? JSONDecoder().decode([PipelineConfig].self, from: data)
        else { return [] }
        return list
    }
}
