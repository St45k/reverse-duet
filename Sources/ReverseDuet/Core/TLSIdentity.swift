import Foundation
import Security

/// Self-signed certificate for the "secure link" (HTTPS/WSS).
///
/// Browsers only expose WebCodecs (hardware H.264 decoding), Wake Lock and
/// Keyboard Lock to secure origins, and a LAN IP over plain HTTP isn't one.
/// The certificate is created once with macOS's bundled LibreSSL and reused;
/// the other device accepts it once via the browser's certificate warning.
enum TLSIdentity {
    private static let passphrase = "reverse-duet"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Reverse Duet/tls", isDirectory: true)
    }

    /// Loads the stored identity, creating it first if needed. Blocking — call off the main thread.
    static func loadOrCreate(hostNames: [String], addresses: [String]) -> SecIdentity? {
        let p12 = directory.appendingPathComponent("identity.p12")
        if let identity = load(p12) { return identity }
        guard create(at: p12, hostNames: hostNames, addresses: addresses) else { return nil }
        return load(p12)
    }

    private static func load(_ url: URL) -> SecIdentity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let options = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
              let entries = items as? [[String: Any]],
              let entry = entries.first,
              let identity = entry[kSecImportItemIdentity as String] else { return nil }
        // swiftlint:disable:next force_cast
        return (identity as! SecIdentity)
    }

    private static func create(at p12: URL, hostNames: [String], addresses: [String]) -> Bool {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = directory.appendingPathComponent("key.pem")
        let cert = directory.appendingPathComponent("cert.pem")
        let config = directory.appendingPathComponent("openssl.cnf")

        var alternativeNames = ["DNS.1 = localhost", "IP.1 = 127.0.0.1"]
        for (index, name) in hostNames.enumerated() { alternativeNames.append("DNS.\(index + 2) = \(name)") }
        for (index, address) in addresses.enumerated() { alternativeNames.append("IP.\(index + 2) = \(address)") }
        let configText = """
        [req]
        distinguished_name = dn
        x509_extensions = v3
        prompt = no
        [dn]
        CN = Reverse Duet (\(Host.current().localizedName ?? "Mac"))
        O = Reverse Duet
        [v3]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = @alt
        [alt]
        \(alternativeNames.joined(separator: "\n"))
        """
        do {
            try configText.write(to: config, atomically: true, encoding: .utf8)
        } catch {
            return false
        }

        let generated = run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "397",
                             "-keyout", key.path, "-out", cert.path, "-config", config.path])
            && run(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path,
                    "-name", "Reverse Duet", "-passout", "pass:\(passphrase)"])
        try? fileManager.removeItem(at: key)
        return generated
    }

    private static func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
