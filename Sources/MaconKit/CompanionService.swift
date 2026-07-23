//
//  CompanionService.swift
//  MaconKit
//
//  Convenience wiring: given the pipelines a `macon watch` is running, stand up
//  the companion server backed by a PairingStore. The app connects, pairs once,
//  then monitors builds and tails logs.
//

import Foundation

@MainActor
public final class CompanionService {
    private let server: CompanionServer
    public let store: PairingStore

    public init(runners: @escaping () -> [PipelineRunner],
                runnerName: String,
                port: UInt16,
                store: PairingStore,
                pool: PipelinePool? = nil,
                screen: ScreenBroadcaster? = nil,
                control: (@Sendable (ControlEvent) -> Void)? = nil,
                apps: (@Sendable () -> CompanionAppsDTO)? = nil,
                windows: (@Sendable () async -> CompanionWindowsDTO)? = nil,
                compactOpen: (@Sendable (CompanionCompactOpenRequestDTO) async -> CompanionCompactOpenResponseDTO?)? = nil,
                screenTarget: (@Sendable (UInt32?) -> Void)? = nil,
                power: (@Sendable () async -> CompanionPowerDTO)? = nil,
                wake: (@Sendable () async -> Void)? = nil,
                unlock: (@Sendable () async -> Bool)? = nil,
                privacy: (@Sendable (_ on: Bool) async -> Bool)? = nil,
                lock: (@Sendable () async -> Bool)? = nil,
                aiModels: (@Sendable () async -> Data?)? = nil,
                aiProviders: (@Sendable () async -> Data?)? = nil,
                aiChat: (@Sendable (_ body: Data, _ emit: @escaping @Sendable (Data) -> Void) async -> Void)? = nil,
                codeOps: CompanionServer.CodeOps? = nil,
                termOps: CompanionServer.TermOps? = nil,
                flowOps: CompanionServer.FlowOps? = nil,
                devices: (@Sendable () async -> Data?)? = nil,
                apnsRegister: (@Sendable (_ bearer: String, _ body: Data) async -> Bool)? = nil,
                agentOps: CompanionServer.AgentOps? = nil,
                onAuthorize: (@Sendable (String) -> Void)? = nil,
                onLog: @escaping @Sendable (String) -> Void) {
        self.store = store
        let data = CompanionData(runners: runners, runnerName: runnerName, pool: pool)

        // Listing, watch toggles, and run-now work everywhere (they only need the
        // runners). Add/edit/delete and provider lookups need a PipelinePool, so
        // they no-op on a headless CLI — the DTO's `managed` flag says which.
        let ops = CompanionServer.PipelineOps(
            list: { await data.pipelines() },
            create: { await data.createPipeline($0) },
            update: { await data.updatePipeline(id: $0, $1) },
            remove: { await data.deletePipeline(id: $0) },
            watch: { await data.setWatching(id: $0, on: $1) },
            run: { await data.runPipeline(id: $0) },
            repos: { await data.listRepos(provider: $0, workspace: $1) },
            branches: { await data.listBranches(provider: $0, workspace: $1, repo: $2) })

        self.server = CompanionServer(
            port: port,
            // Every authorized request marks its device as seen — that's the
            // liveness signal behind the fleet map.
            authorize: { token in
                let ok = store.authorize(token)
                if ok { onAuthorize?(token) }
                return ok
            },
            pair: { code, device in
                guard let token = store.pair(code: code, device: device) else { return nil }
                return CompanionPairResponseDTO(token: token, runnerName: runnerName)
            },
            builds: { await data.builds() },
            build: { await data.build(id: $0) },
            logsSince: { await data.linesSince(buildID: $0, afterSeq: $1) },
            buildAction: { id, action in
                guard let act = CompanionData.BuildAction(rawValue: action) else { return false }
                return await data.perform(act, buildID: id)
            },
            pipelineOps: ops,
            metrics: { await data.metricsText() },
            screen: screen,
            control: control,
            apps: apps,
            windows: windows,
            compactOpen: compactOpen,
            screenTarget: screenTarget,
            power: power,
            wake: wake,
            unlock: unlock,
            privacy: privacy,
            lock: lock,
            aiModels: aiModels,
            aiProviders: aiProviders,
            aiChat: aiChat,
            codeOps: codeOps,
            termOps: termOps,
            flowOps: flowOps,
            devices: devices,
            apnsRegister: apnsRegister,
            agentOps: agentOps,
            onLog: onLog)
    }

    public func start() { server.start() }
    public func stop() { server.stop() }
}
