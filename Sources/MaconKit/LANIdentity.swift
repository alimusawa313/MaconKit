//
//  LANIdentity.swift
//  MaconKit
//
//  The TLS identity the companion server presents on the LAN.
//
//  Cloudflare terminates TLS for the tunnel, so anything arriving that way is
//  already encrypted. A device connecting straight to the Mac over Wi-Fi was
//  not: the `Authorization: Bearer <token>` header, and the token in a pairing
//  response, crossed the local network in the clear, where anyone on the same
//  Wi-Fi could take one and drive the Mac with it. Hence a self-signed
//  certificate, generated once per Mac, that paired devices pin.
//
//  Pinning rather than a trusted chain is deliberate: there is no CA in this
//  picture, the address is an IP or a .local name that changes, and the client
//  compares the certificate it is offered against one exact value it learned
//  over an already-trusted channel. Hostname and expiry are therefore not
//  load-bearing here, which is why the certificate carries a long life and
//  courtesy names.
//
//  It lives as a file next to devices.json, at 0600 inside a 0700 directory,
//  because both the app and `macon watch --companion` serve on the LAN and have
//  to present the same certificate. A keychain item would be scoped to whichever
//  of the two created it, and reading it from the other prompts the user. The
//  passphrase below is a constant for the same reason: anything that can read
//  the file could read a passphrase stored beside it, so the file mode is the
//  real protection and pretending otherwise would only obscure that.
//

import Foundation
import Security
import CryptoKit

public enum LANIdentity {

    public struct Loaded {
        public let identity: SecIdentity
        /// Base64 SHA-256 of the certificate's DER. This is what a client pins,
        /// what `GET /lan` serves, and what a pairing response carries.
        public let pin: String
    }

    /// See the note above on why this is a constant.
    private static let passphrase = "macon-lan-identity"

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacON/companion/lan-identity.p12")
    }

    /// Load the Mac's identity, generating one the first time. Nil means the LAN
    /// listener cannot come up; the caller keeps serving the tunnel rather than
    /// falling back to cleartext on the LAN.
    public static func loadOrCreate(log: (String) -> Void) -> Loaded? {
        if let existing = load() { return existing }
        guard generate(log: log) else { return nil }
        guard let fresh = load() else {
            log("✗ LAN TLS: made a certificate but could not read it back")
            return nil
        }
        log("🔐 LAN TLS: new certificate for this Mac, pin \(fresh.pin)")
        return fresh
    }

    /// The pin on its own, for a client on this same Mac (the CLI) that can read
    /// the file rather than being told the value.
    public static func pin() -> String? { load()?.pin }

    // MARK: Internals

    private static func load() -> Loaded? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData,
                                     [kSecImportExportPassphrase as String: passphrase] as CFDictionary,
                                     &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let raw = first[kSecImportItemIdentity as String] else { return nil }
        let identity = raw as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { return nil }
        let der = SecCertificateCopyData(certificate) as Data
        return Loaded(identity: identity, pin: Data(SHA256.hash(data: der)).base64EncodedString())
    }

    private static func generate(log: (String) -> Void) -> Bool {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        // Key and certificate exist as files for as long as openssl needs to
        // turn them into a p12, so give them a 0700 directory of their own and
        // take it away again on the way out.
        let work = dir.appendingPathComponent("lan-identity-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: work, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])) != nil else {
            log("✗ LAN TLS: no writable directory for the certificate")
            return false
        }
        defer { try? fm.removeItem(at: work) }

        let conf = work.appendingPathComponent("openssl.cnf")
        let key = work.appendingPathComponent("key.pem")
        let cert = work.appendingPathComponent("cert.pem")
        let p12 = work.appendingPathComponent("identity.p12")

        guard (try? Data(config().utf8).write(to: conf)) != nil else { return false }
        // RSA is not a free choice: SecPKCS12Import crashes outright on an EC
        // key inside a p12 written by the system LibreSSL. The key is written
        // encrypted (no -nodes) so it is not sitting in the clear even for the
        // few milliseconds it exists.
        guard openssl(["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "7300",
                       "-keyout", key.path, "-out", cert.path,
                       "-config", conf.path, "-extensions", "v3",
                       "-passout", "pass:\(passphrase)"], log: log),
              openssl(["pkcs12", "-export", "-out", p12.path,
                       "-inkey", key.path, "-passin", "pass:\(passphrase)",
                       "-in", cert.path, "-name", "MacON companion",
                       "-passout", "pass:\(passphrase)"], log: log),
              let data = try? Data(contentsOf: p12) else { return false }

        try? fm.removeItem(at: fileURL)
        // 0600 applied as the file comes into being, so the private key is never
        // readable by anyone else, not even for the width of the write.
        guard fm.createFile(atPath: fileURL.path, contents: data,
                            attributes: [.posixPermissions: 0o600]) else {
            log("✗ LAN TLS: could not write \(fileURL.lastPathComponent)")
            return false
        }
        return true
    }

    /// Names are a courtesy: clients pin the certificate, so nothing depends on
    /// a SAN matching whatever address someone typed. They only make life
    /// easier for a curl or a Prometheus scraper pointed at the Mac with
    /// --cacert. The hostname is filtered rather than trusted, because it ends
    /// up in a config file that openssl parses.
    private static func config() -> String {
        var names = ["DNS:localhost", "IP:127.0.0.1"]
        let host = ProcessInfo.processInfo.hostName
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        if !host.isEmpty, host.count < 200, host.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            names.insert("DNS:\(host)", at: 1)
        }
        return """
        [req]
        distinguished_name = dn
        x509_extensions = v3
        prompt = no
        [dn]
        CN = MacON companion
        [v3]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = \(names.joined(separator: ", "))
        """
    }

    private static func openssl(_ arguments: [String], log: (String) -> Void) -> Bool {
        let tool = URL(fileURLWithPath: "/usr/bin/openssl")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            log("✗ LAN TLS: /usr/bin/openssl is missing, cannot make a certificate")
            return false
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            log("✗ LAN TLS: could not run openssl, \(error.localizedDescription)")
            return false
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            log("✗ LAN TLS: openssl \(arguments.first ?? "") failed, \(text)")
            return false
        }
        return true
    }
}
