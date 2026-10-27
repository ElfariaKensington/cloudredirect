import Foundation
import CloudRedirectSupport

extension NativeBackend {
    func manifestSettings() -> [String: Any] {
        ["enabled": config["manifest_pinning"] as? Bool ?? false, "autoComment": config["auto_comment"] as? Bool ?? true, "pinnedApps": config["pinned_apps"] as? [Int] ?? []]
    }
    func manifestApps() -> [[String: Any]] {
        let directory = disk.steam.appendingPathComponent("config/stplug-in")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let pattern = try! NSRegularExpression(pattern: #"setManifestid\s*\(\s*[0-9]+\s*,\s*"[0-9]+""#, options: .caseInsensitive)
        let result: [[String: Any]] = files.compactMap { file in
            guard file.pathExtension == "lua", let id = Int(file.deletingPathExtension().lastPathComponent), id > 0 else { return nil }
            let text = disk.text(file).split(separator: "\n").map { $0.components(separatedBy: "--").first ?? "" }.joined(separator: "\n")
            return ["appId": id, "name": gameName(id), "pins": pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))]
        }
        Task { await resolveNames(Set(result.map { number($0, "appId") })); store.manifestGames = result.map { var row = $0; row["name"] = gameName(number(row, "appId")); return row } }
        return result
    }
    func scanOrphans() -> [[String: Any]] {
        disk.directories(disk.storage.appendingPathComponent(account.id)).compactMap { directory in
            guard let id = Int(directory.lastPathComponent), id > 0 else { return nil }
            let referenced = Set(disk.text(directory.appendingPathComponent("file_tokens.dat")).split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: "\t", maxSplits: 1); return parts.count == 2 ? String(parts[0]) : nil
            })
            let blobs = (try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("blobs"), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
            let orphans = blobs.filter {
                let info = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return info?.isRegularFile == true && info?.isSymbolicLink != true && !referenced.contains($0.lastPathComponent) && !["Playtime.bin", "UserGameStats.bin"].contains($0.lastPathComponent)
            }
            guard !orphans.isEmpty else { return nil }
            let bytes = orphans.reduce(Int64(0)) { $0 + disk.size($1) }
            return ["appId": id, "name": gameName(id), "orphanCount": orphans.count, "orphanSize": bytes, "orphanSizeFormatted": disk.formatted(bytes)]
        }
    }
    func listBackups() -> [[String: Any]] {
        guard !account.id.isEmpty else { return [] }
        return disk.directories(backupRoot).map { directory in
            let undo = disk.json(directory.appendingPathComponent("undo_log.json"))
            let files = disk.regularFiles(directory).filter { $0.lastPathComponent != "undo_log.json" }
            let bytes = files.reduce(Int64(0)) { $0 + disk.size($1) }
            return ["path": directory.path, "name": directory.lastPathComponent, "timestamp": undo["timestamp"] ?? "", "appId": undo["appId"] ?? 0, "accountId": undo["accountId"] ?? account.id, "fileCount": files.count, "totalSize": bytes, "sizeFormatted": disk.formatted(bytes)]
        }
    }
    func validBackup(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        guard !account.id.isEmpty, disk.contains(backupRoot, url), url.deletingLastPathComponent().standardizedFileURL == backupRoot.standardizedFileURL else { throw AppError.message("Invalid backup path.") }
        return url
    }
    func restoreBackup(_ path: String) throws -> String {
        let backup = try validBackup(path)
        let undo = disk.json(backup.appendingPathComponent("undo_log.json"))
        guard let operations = undo["operations"] as? [[String: Any]], string(undo, "accountId") == account.id, number(undo, "appId") > 0 else { throw AppError.message("Cannot read this backup's recovery inventory.") }
        let appID = String(number(undo, "appId"))
        let allowed = [disk.storage.appendingPathComponent(account.id).appendingPathComponent(appID), disk.steam.appendingPathComponent("userdata").appendingPathComponent(account.id).appendingPathComponent(appID)]
        var restored = 0, skipped = 0
        for operation in operations {
            let file = URL(fileURLWithPath: string(operation, "dest")), target = URL(fileURLWithPath: string(operation, "source"))
            guard string(operation, "type") == "file_copy", disk.contains(backup, file), allowed.contains(where: { disk.contains($0, target) }) else { skipped += 1; continue }
            do {
                let data = try Data(contentsOf: file)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic); restored += 1
            } catch { skipped += 1 }
        }
        rebuildGames()
        return "Restored \(restored) file(s), \(skipped) skipped."
    }
    func deleteBackup(_ path: String) throws { try FileManager.default.removeItem(at: validBackup(path)) }
    func deleteAppData(_ id: Int) async throws {
        guard id > 0, id <= 0xffffff, !account.id.isEmpty else { throw AppError.message("Invalid game or Steam account.") }
        let sources = [disk.storage.appendingPathComponent(account.id).appendingPathComponent(String(id)), disk.steam.appendingPathComponent("userdata").appendingPathComponent(account.id).appendingPathComponent(String(id))]
        let backup = backupRoot.appendingPathComponent("\(id)_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8))")
        var operations: [[String: Any]] = []
        for (index, source) in sources.enumerated() {
            let files = disk.regularFiles(source)
            for file in files {
                guard disk.contains(source, file) else { throw AppError.message("Unexpected save path; removal cancelled.") }
                let relative = String(file.path.dropFirst(source.path.count + 1))
                let target = backup.appendingPathComponent(index == 0 ? "storage" : "userdata").appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: target)
                operations.append(["type": "file_copy", "source": file.path, "dest": target.path, "appId": id])
            }
        }
        try disk.write(["version": 1, "timestamp": ISO8601DateFormatter().string(from: Date()), "appId": id, "accountId": account.id, "operations": operations], to: backup.appendingPathComponent("undo_log.json"))
        if remoteIDs.contains(id) { _ = try await command(["delete-remote-app", provider, account.id, String(id)]).json() }
        for source in sources where FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
        remoteIDs.remove(id); rebuildGames()
    }
}
