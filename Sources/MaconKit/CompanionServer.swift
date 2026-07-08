//
//  CompanionServer.swift
//  MaconKit
//
//  HTTP + WebSocket server for the companion app. Zero dependencies
//  (Network.framework), same style as WebhookServer. Routes:
//
//    POST /pair                 (no auth)  device-code → token
//    GET  /builds               (Bearer)   build list
//    GET  /builds/{id}          (Bearer)   one build
//    WS   /builds/{id}/logs     (Bearer)   live log tail
//
//  Meant to sit behind a cloudflared tunnel (which terminates TLS), so a
//  headless EC2 Mac is reachable at a stable https/wss URL.
//

import Foundation
import Network
import CryptoKit

public final class CompanionServer: @unchecked Sendable {

    public typealias Authorize = @Sendable (String) -> Bool
    public typealias Pair = @Sendable (_ code: String, _ device: String) async -> CompanionPairResponseDTO?
    public typealias Builds = @Sendable () async -> CompanionBuildsDTO
    public typealias Build = @Sendable (_ id: String) async -> CompanionBuildDTO?
    public typealias LogsSince = @Sendable (_ id: String, _ afterSeq: Int) async -> [CompanionLogDTO]

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "macon.companion")
    private var listener: NWListener?

    private let authorize: Authorize
    private let pair: Pair
    private let builds: Builds
    private let build: Build
    private let logsSince: LogsSince
    private let onLog: @Sendable (String) -> Void

    public init(port: UInt16,
                authorize: @escaping Authorize,
                pair: @escaping Pair,
                builds: @escaping Builds,
                build: @escaping Build,
                logsSince: @escaping LogsSince,
                onLog: @escaping @Sendable (String) -> Void) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 8899
        self.authorize = authorize
        self.pair = pair
        self.builds = builds
        self.build = build
        self.logsSince = logsSince
        self.onLog = onLog
    }

    // MARK: Lifecycle

    public func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            do {
                let l = try NWListener(using: params, on: port)
                l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                l.start(queue: queue)
                listener = l
                onLog("📡 Companion server listening on :\(port.rawValue)")
            } catch {
                onLog("✗ Companion couldn't bind port \(port.rawValue): \(error.localizedDescription)")
            }
        }
    }

    public func stop() {
        queue.async { [self] in listener?.cancel(); listener = nil }
    }

    // MARK: Request lifecycle

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    /// Accumulate until the full header block (and any POST body) has arrived.
    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var acc = buffer
            if let data, !data.isEmpty { acc.append(data) }
            guard let sep = acc.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil { conn.cancel() } else { self.readRequest(conn, buffer: acc) }
                return
            }
            let header = String(data: acc.subdata(in: acc.startIndex..<sep.lowerBound), encoding: .utf8) ?? ""
            let contentLength = self.headerInt(header, "content-length") ?? 0
            let have = acc.distance(from: sep.upperBound, to: acc.endIndex)
            if have < contentLength && !isComplete && error == nil {
                self.readRequest(conn, buffer: acc); return
            }
            let body = acc.subdata(in: sep.upperBound..<acc.endIndex)
            self.route(conn, header: header, body: body)
        }
    }

    private func route(_ conn: NWConnection, header: String, body: Data) {
        let requestLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map { $0.uppercased() } ?? ""
        let rawPath = parts.count > 1 ? String(parts[1]) : "/"
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
        let segs = path.split(separator: "/").map(String.init)

        // POST /pair — the only unauthenticated route.
        if method == "POST", path == "/pair" {
            Task {
                guard let req = try? CompanionJSON.decoder.decode(CompanionPairRequestDTO.self, from: body),
                      let resp = await self.pair(req.code, req.deviceName) else {
                    self.respond(conn, "401 Unauthorized", json: nil); return
                }
                self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(resp))
            }
            return
        }

        // Everything else needs a valid bearer token.
        guard let token = bearer(header), authorize(token) else {
            respond(conn, "401 Unauthorized", json: nil); return
        }

        // WS /builds/{id}/logs
        if method == "GET", segs.count == 3, segs[0] == "builds", segs[2] == "logs",
           headerValue(header, "upgrade")?.lowercased() == "websocket" {
            upgradeAndStream(conn, header: header, buildID: segs[1]); return
        }

        // GET /builds
        if method == "GET", path == "/builds" {
            Task { self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(await self.builds())) }
            return
        }

        // GET /builds/{id}
        if method == "GET", segs.count == 2, segs[0] == "builds" {
            Task {
                guard let b = await self.build(segs[1]) else { self.respond(conn, "404 Not Found", json: nil); return }
                self.respond(conn, "200 OK", json: try? CompanionJSON.encoder.encode(b))
            }
            return
        }

        respond(conn, "404 Not Found", json: nil)
    }

    // MARK: Plain HTTP response (closes the connection)

    private func respond(_ conn: NWConnection, _ status: String, json: Data?) {
        let payload = json ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(payload)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: WebSocket

    /// One live log connection. `open` gates the push loop; the reader flips it
    /// when the client disconnects.
    private final class WSState: @unchecked Sendable { var open = true; var lastSeq = -1 }

    private func upgradeAndStream(_ conn: NWConnection, header: String, buildID: String) {
        guard let key = headerValue(header, "sec-websocket-key") else { respond(conn, "400 Bad Request", json: nil); return }
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data((key + magic).utf8))).base64EncodedString()
        let handshake = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"

        let state = WSState()
        conn.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.drainClient(conn, state: state)   // detect close
            self.pushLoop(conn, buildID: buildID, state: state)
        })
    }

    /// Poll for new log lines and push them as text frames until the client goes.
    private func pushLoop(_ conn: NWConnection, buildID: String, state: WSState) {
        guard state.open else { conn.cancel(); return }
        Task {
            let lines = await self.logsSince(buildID, state.lastSeq)
            for line in lines {
                guard let data = try? CompanionJSON.encoder.encode(line) else { continue }
                self.send(conn, frame: data)
                state.lastSeq = max(state.lastSeq, line.seq)
            }
            self.queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.pushLoop(conn, buildID: buildID, state: state)
            }
        }
    }

    /// We don't parse inbound frames — just notice when the socket closes.
    private func drainClient(_ conn: NWConnection, state: WSState) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil { state.open = false; conn.cancel(); return }
            self?.drainClient(conn, state: state)
        }
    }

    /// Encode one unmasked server→client text frame (RFC 6455 §5).
    private func send(_ conn: NWConnection, frame payload: Data) {
        var frame = Data([0x81])                    // FIN + text opcode
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(n))
        } else if n <= 0xFFFF {
            frame.append(126); frame.append(UInt8(n >> 8)); frame.append(UInt8(n & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((n >> shift) & 0xFF)) }
        }
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    // MARK: Header helpers

    private func bearer(_ header: String) -> String? {
        guard let v = headerValue(header, "authorization"), v.lowercased().hasPrefix("bearer ") else { return nil }
        return String(v.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }

    private func headerValue(_ header: String, _ name: String) -> String? {
        for line in header.split(separator: "\r\n").dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func headerInt(_ header: String, _ name: String) -> Int? {
        headerValue(header, name).flatMap { Int($0) }
    }
}
