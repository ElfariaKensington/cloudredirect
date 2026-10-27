import CryptoKit
import Foundation

public enum RuntimeContent {
    public static func fingerprint(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        let magic = data.prefix(4).map { String(format: "%02x", $0) }.joined()
        let executable = ["cffaedfe", "feedfacf", "cefaedfe", "feedface", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"].contains(magic)
        if !executable { return Data(SHA256.hash(data: data)) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("payload")
        try data.write(to: copy)
        // Re-signing during installation must not count as a content update.
        _ = try RuntimeInstaller.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--remove-signature", copy.path])
        return Data(SHA256.hash(data: try Data(contentsOf: copy)))
    }

    public static func current(resources: URL = RuntimeInstaller.resources, installed: URL = RuntimeInstaller.executableDirectory) throws -> Bool {
        for name in ["cloud_redirect.dylib", "cloud_redirect_credentials"] {
            let target = installed.appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: target.path) else { return false }
            if try fingerprint(resources.appendingPathComponent(name)) != fingerprint(target) { return false }
        }
        return true
    }
}
