//
//  RunnerPool.swift
//  MacON
//
//  Manages the set of runners and shared machine-cache cleanup.
//

import Foundation
import Combine

@MainActor
public final class RunnerPool: ObservableObject {

    @Published public private(set) var agents: [RunnerAgent] = []
    @Published public var cleanupSettings: CleanupSettings {
        didSet {
            persistSettings()
            for agent in agents { agent.cleanupSettings = cleanupSettings }
        }
    }
    @Published public var isCleaningCaches = false
    @Published public var lastCacheReport: CleanReport?
    @Published public var reclaimableBytes: Int64 = 0

    private let defaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()
    private enum Keys {
        static let instances = "pool.instances"
        static let settings = "pool.cleanupSettings"
    }

    public init() {
        cleanupSettings = Self.loadSettings()
        for instance in Self.loadInstances() {
            let agent = RunnerAgent(instance: instance, cleanupSettings: cleanupSettings)
            observe(agent)
            agents.append(agent)
        }
    }

    /// Forward a child's changes so views observing only the pool (e.g. the menu
    /// bar) refresh when a runner's state changes.
    private func observe(_ agent: RunnerAgent) {
        agent.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Derived

    public var activeCount: Int { agents.filter { $0.state.isActive }.count }
    public var anyActive: Bool { activeCount > 0 }

    // MARK: - Mutating the pool

    @discardableResult
    public func addRunner() -> RunnerAgent {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var instance = RunnerInstance()
        instance.name = "Runner \(agents.count + 1)"
        instance.workingDirectory = "\(home)/bitbucket-runners/\(instance.id.uuidString.prefix(8))"
        let agent = RunnerAgent(instance: instance, cleanupSettings: cleanupSettings)
        observe(agent)
        agents.append(agent)
        persistInstances()
        return agent
    }

    public func remove(_ agent: RunnerAgent) {
        if agent.state.isActive { agent.stop() }
        agents.removeAll { $0.id == agent.id }
        persistInstances()
    }

    /// Persist after editing a runner's fields via the binding in the edit sheet.
    public func commitEdits() { persistInstances() }

    public func startAll() { for a in agents { a.start() } }
    public func stopAll()  { for a in agents where a.state.isActive { a.stop() } }

    // MARK: - Shared cache cleanup

    /// Refuses to run while any runner is active — wiping shared DerivedData
    /// mid-build would corrupt whichever runner is building.
    public func cleanCaches() {
        guard !isCleaningCaches else { return }
        guard !anyActive else { return }
        isCleaningCaches = true
        let plan = cleanupSettings.cachePlan
        Task { @MainActor in
            let report = await Cleaner.clean(plan)
            self.lastCacheReport = report
            self.isCleaningCaches = false
            await self.refreshReclaimable()
        }
    }

    public func refreshReclaimable() async {
        reclaimableBytes = await Cleaner.estimate(cleanupSettings.cachePlan)
    }

    // MARK: - Persistence

    private func persistInstances() {
        let instances = agents.map(\.instance)
        if let data = try? JSONEncoder().encode(instances) {
            defaults.set(data, forKey: Keys.instances)
        }
    }
    private func persistSettings() {
        if let data = try? JSONEncoder().encode(cleanupSettings) {
            defaults.set(data, forKey: Keys.settings)
        }
    }
    private static func loadInstances() -> [RunnerInstance] {
        guard let data = UserDefaults.standard.data(forKey: Keys.instances),
              let list = try? JSONDecoder().decode([RunnerInstance].self, from: data)
        else { return [] }
        return list
    }
    private static func loadSettings() -> CleanupSettings {
        guard let data = UserDefaults.standard.data(forKey: Keys.settings),
              let s = try? JSONDecoder().decode(CleanupSettings.self, from: data)
        else { return CleanupSettings() }
        return s
    }
}
