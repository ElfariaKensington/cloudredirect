import Foundation
import CloudRedirectSupport

enum SteamKeyValues {
    static func parse(_ text: String) -> [String: Any] {
        let pattern = #"//[^\r\n]*|"((?:\\.|[^"\\])*)"|([{}])|([^\s{}"]+)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        let tokens = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match -> String? in
            if ns.substring(with: match.range).hasPrefix("//") { return nil }
            if match.range(at: 1).location != NSNotFound { return ns.substring(with: match.range(at: 1)).replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: "\\") }
            return ns.substring(with: match.range)
        }
        var index = 0
        func object() -> [String: Any] {
            var result: [String: Any] = [:]
            while index < tokens.count {
                let key = tokens[index]; index += 1
                if key == "}" { break }
                guard index < tokens.count else { break }
                let value = tokens[index]; index += 1
                result[key] = value == "{" ? object() : value
            }
            return result
        }
        return object()
    }
}

struct NativeStorage {
    let root: URL
    let steam: URL
    let files = FileManager.default
    var configURL: URL { root.appendingPathComponent("config.json") }
    var storage: URL { root.appendingPathComponent("storage") }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configHome = environment["CLOUDREDIRECT_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("Library/Application Support")
        root = configHome.appendingPathComponent("CloudRedirect")
        steam = environment["CLOUDREDIRECT_STEAM_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("Library/Application Support/Steam")
    }

    func json(_ url: URL) -> [String: Any] { (try? Data(contentsOf: url)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:] }
    func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func write(_ object: [String: Any], to url: URL) throws {
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func directories(_ url: URL) -> [URL] {
        ((try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []).filter {
            let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }
    func regularFiles(_ url: URL) -> [URL] {
        guard let enumerator = files.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return [] }
        return enumerator.compactMap { value in
            guard let file = value as? URL, let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), info.isRegularFile == true, info.isSymbolicLink != true else { return nil }
            return file
        }
    }
    func contains(_ root: URL, _ child: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = child.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(base + "/")
    }
    func size(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    func formatted(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    func account() -> (id: String, name: String) {
        let users = SteamKeyValues.parse(text(steam.appendingPathComponent("config/loginusers.vdf")))["users"] as? [String: [String: Any]] ?? [:]
        let sorted = users.sorted { lhs, rhs in
            func rank(_ user: [String: Any]) -> [Int64] { [Int64(user["MostRecent"] as? String ?? "0") ?? 0, Int64(user["AutoLogin"] as? String ?? "0") ?? 0, Int64(user["Timestamp"] as? String ?? "0") ?? 0] }
            return rank(rhs.value).lexicographicallyPrecedes(rank(lhs.value))
        }
        guard let best = sorted.first, let steamID = UInt64(best.key), steamID > 76561197960265728 else { return ("", "") }
        return (String(steamID & 0xffffffff), best.value["PersonaName"] as? String ?? "")
    }

    func localGames(account: String, cache: [String: [String: Any]]) -> [[String: Any]] {
        guard !account.isEmpty else { return [] }
        let metadata: Set<String> = ["cn.dat", "root_token.dat", "file_tokens.dat", "deleted.dat"]
        return directories(storage.appendingPathComponent(account)).compactMap { directory in
            guard let id = Int(directory.lastPathComponent), id > 0, ![7, 760, 2371090].contains(id) else { return nil }
            let blobs = regularFiles(directory).filter { !metadata.contains($0.lastPathComponent) }
            let total = blobs.reduce(Int64(0)) { $0 + size($1) }
            return ["appId": id, "name": cache[String(id)]?["name"] as? String ?? "Unknown game", "fileCount": blobs.count, "totalSize": total, "sizeFormatted": formatted(total), "isLocal": true, "isRemote": false, "headerUrl": cache[String(id)]?["headerUrl"] as? String ?? "https://shared.steamstatic.com/store_item_assets/steam/apps/\(id)/header.jpg"]
        }
    }
}
