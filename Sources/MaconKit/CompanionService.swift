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
                screen: ScreenBroadcaster? = nil,
                control: (@Sendable (ControlEvent) -> Void)? = nil,
                onLog: @escaping @Sendable (String) -> Void) {
        self.store = store
        let data = CompanionData(runners: runners, runnerName: runnerName)
        self.server = CompanionServer(
            port: port,
            authorize: { store.authorize($0) },
            pair: { code, device in
                guard let token = store.pair(code: code, device: device) else { return nil }
                return CompanionPairResponseDTO(token: token, runnerName: runnerName)
            },
            builds: { await data.builds() },
            build: { await data.build(id: $0) },
            logsSince: { await data.linesSince(buildID: $0, afterSeq: $1) },
            screen: screen,
            control: control,
            onLog: onLog)
    }

    public func start() { server.start() }
    public func stop() { server.stop() }
}
