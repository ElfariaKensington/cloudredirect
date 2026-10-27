import Foundation
import CloudRedirectSupport

extension NativeBackend {
    func saveCredentials(_ provider: String, args: [Any]) async throws -> Bool {
        let keys = provider == "r2" ? ["account_id", "access_key_id", "secret_access_key", "bucket", "key_prefix", "endpoint"] : ["access_key_id", "secret_access_key", "bucket", "endpoint", "region", "key_prefix", "sign_payload", "allow_insecure_http", "allow_insecure_tls", "ca_cert_path"]
        guard args.count == keys.count else { throw AppError.message("Invalid provider credentials.") }
        var values = Dictionary(uniqueKeysWithValues: zip(keys, args))
        for key in keys where values[key] is String { values[key] = (values[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if (values["secret_access_key"] as? String ?? "").isEmpty { values["secret_access_key"] = try await credentials(provider)["secret_access_key"] }
        let required = provider == "r2" ? ["account_id", "access_key_id", "secret_access_key", "bucket"] : ["access_key_id", "secret_access_key", "bucket", "endpoint", "region"]
        guard required.allSatisfy({ !(values[$0] as? String ?? "").isEmpty }) else { throw AppError.message("Fill in the required provider credentials.") }
        let path = tokenPath(provider)
        let result = try await command(["store-credentials-path", path], input: JSONSerialization.data(withJSONObject: values))
        guard result.status == 0 else { throw AppError.message("Could not save provider credentials in Keychain.") }
        var paths = config["token_paths"] as? [String: String] ?? [:]; paths[provider] = path; config["token_paths"] = paths
        try save(); try await refreshStatus(); return true
    }
    func cloudFiles(_ method: String, args: [Any]) async throws {
        guard let id = args.first as? Int, id > 0, id <= 0xffffff else { throw AppError.message("Choose a valid game.") }
        let community = method.hasPrefix("steam"), deleting = method.hasSuffix("Delete")
        let names = args.count > 1 ? args[1] as? [String] ?? [] : []
        guard !deleting || !names.isEmpty else { throw AppError.message("Select at least one file.") }
        store.cloudBusy = true
        defer { store.cloudBusy = false }
        do {
            var files: [[String: Any]]
            if community {
                let executable = Bundle.main.resourceURL!.appendingPathComponent("runtime/cloud760_tool")
                if deleting {
                    let result = try await NativeCommand().run(executable, ["delete", String(id), "--porcelain"] + names)
                    guard result.status == 0 else { throw AppError.message(result.errors) }
                }
                let result = try await NativeCommand().run(executable, ["list", String(id), "--porcelain"])
                guard result.status == 0 else { throw AppError.message(result.errors) }
                var count: Int?
                files = []
                for line in String(decoding: result.data, as: UTF8.self).split(separator: "\n") {
                    let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    if fields.first == "COUNT", fields.count >= 2 { count = Int(fields[1]) }
                    if fields.first == "FILE", fields.count >= 4 { files.append(["name": fields[1], "size": Int64(fields[2]) ?? 0, "persisted": fields[3] == "1"]) }
                }
                guard count == files.count else { throw AppError.message("Steam returned an incomplete file listing.") }
            } else {
                guard remoteIDs.contains(id), !account.id.isEmpty else { throw AppError.message("Choose a game with cloud data.") }
                let args = [deleting ? "delete-cloud-save-files" : "list-cloud-save-files", provider, account.id, String(id)] + (deleting ? ["--confirmed"] + names : [])
                let json = try await command(args).json(); files = json["files"] as? [[String: Any]] ?? []
            }
            guard store.cloudCommunity == community, (community ? 760 : store.cloudAppID) == id else { return }
            store.cloudFiles = files; store.cloudStatus = "\(files.count) files"
        } catch {
            store.cloudStatus = error.localizedDescription
            throw error
        }
    }
    func scanProvider(_ provider: String) async throws {
        migrationCommand?.cancel()
        let generation = UUID(); migrationGeneration = generation
        let command = NativeCommand(); migrationCommand = command
        store.migrationBusy = true; store.migrationScanned = false; store.migrationApps = []
        defer { if migrationGeneration == generation { store.migrationBusy = false; migrationCommand = nil } }
        do {
            let json = try await command.run(cli, ["scan-all", provider]).json()
            guard migrationGeneration == generation else { return }
            store.migrationApps = (json["apps"] as? [[String: Any]] ?? []).compactMap {
                guard let id = Int(string($0, "app_id")), id > 0 else { return nil }
                return ["appId": id, "accountId": string($0, "account_id")]
            }
            store.migrationScanned = true; store.migrationStatus = "\(store.migrationApps.count) games found."
            await resolveNames(Set(store.migrationApps.map { number($0, "appId") }))
        } catch is CancellationError { store.migrationStatus = "Scan cancelled." }
        catch { store.migrationStatus = error.localizedDescription; throw error }
    }
    func migrate(_ source: String, _ destination: String) async throws {
        guard !store.migrationBusy else { throw AppError.message("Wait for the current cloud operation to finish.") }
        let command = NativeCommand(); migrationCommand = command
        let generation = UUID(); migrationGeneration = generation
        store.migrationBusy = true; store.migrationStatus = "Starting migration…"
        defer { store.migrationBusy = false; migrationCommand = nil }
        do {
            let result = try await command.run(cli, ["migrate", source, destination], onLine: { [weak self] line in
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
                Task { @MainActor in
                    guard let self, self.migrationGeneration == generation, self.store.migrationBusy else { return }
                    switch string(object, "type") {
                    case "status", "error": self.store.migrationStatus = string(object, "message")
                    case "start": self.store.migrationStatus = "Migrating \(number(object, "total")) files…"
                    case "progress", "skip": self.store.migrationStatus = "\(number(object, "done")) / \(number(object, "total")) · \(string(object, "file"))"
                    default: break
                    }
                }
            })
            let events = result.data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
            guard result.status == 0, let completed = events.last(where: { string($0, "type") == "complete" }) else {
                throw AppError.message(events.last(where: { string($0, "type") == "error" }).map { string($0, "message") } ?? "Migration did not complete.")
            }
            let failed = number(completed, "failed")
            store.migrationStatus = "\(number(completed, "migrated")) migrated · \(number(completed, "skipped")) skipped · \(failed) failed"
            if failed == 0 { try await set("providerName", value: destination) }
        } catch is CancellationError { store.migrationStatus = "Migration cancelled. Already copied files are retained." }
        catch { store.migrationStatus = error.localizedDescription; throw error }
    }
}
