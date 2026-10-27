import AppKit
import Foundation
import CloudRedirectSupport

@MainActor final class NativeBackend {
    unowned let store: BackendStore
    let disk: NativeStorage
    var config: [String: Any]
    var cache: [String: [String: Any]]
    var remoteIDs: Set<Int> = []
    var authenticated = false
    var fetchingRemote = false
    var resolvingNames = false
    var pendingNameIDs: Set<Int> = []
    var migrationCommand: NativeCommand?
    var migrationGeneration = UUID()
    var account: (id: String, name: String)
    var provider: String { config["provider"] as? String ?? "local" }
    var cli: URL { Bundle.main.resourceURL!.appendingPathComponent("runtime/cloud_redirect_cli") }
    var backupRoot: URL { disk.root.appendingPathComponent("backups").appendingPathComponent(account.id) }

    init(store: BackendStore, disk: NativeStorage = NativeStorage()) {
        self.store = store; self.disk = disk
        config = disk.json(disk.configURL)
        cache = disk.json(disk.root.appendingPathComponent("store_cache.json")) as? [String: [String: Any]] ?? [:]
        account = disk.account()
    }
    func tokenPath(_ provider: String) -> String {
        if let path = (config["token_paths"] as? [String: String])?[provider], !path.isEmpty { return path }
        if provider == self.provider, let path = config["token_path"] as? String, !path.isEmpty { return path }
        return disk.root.appendingPathComponent(["r2", "s3"].contains(provider) ? "\(provider)_credentials.json" : "tokens_\(provider).json").path
    }
    func property(_ key: String) -> Any? {
        switch key {
        case "steamPath": return disk.steam.path
        case "providerName": return provider
        case "providerPath": return tokenPath(provider)
        case "syncFolderPath": return config["sync_folder_path"] ?? config["sync_path"] ?? ""
        case "providerAuthenticated": return authenticated
        case "accountId": return account.id
        case "accountName": return account.name
        case "version": return "2.6.6-macos"
        case "deployed": return FileManager.default.fileExists(atPath: RuntimeInstaller.runtime.path)
        case "managedAppCount": return store.games.filter { $0["isLocal"] as? Bool == true }.count
        case "remoteOnlyAppCount": return store.games.filter { $0["isLocal"] as? Bool != true && $0["isRemote"] as? Bool == true }.count
        default:
            let keys = ["notificationsEnabled": "notifications_enabled", "statsSyncEnabled": "stats_sync_enabled", "syncAchievements": "sync_achievements", "syncPlaytime": "sync_playtime", "syncLuas": "sync_luas"]
            return keys[key].map { config[$0] ?? ["notificationsEnabled", "statsSyncEnabled"].contains(key) }
        }
    }
    func publish() {
        for key in ["providerName", "providerPath", "syncFolderPath", "providerAuthenticated", "accountId", "accountName", "version", "deployed", "managedAppCount", "remoteOnlyAppCount", "notificationsEnabled", "statsSyncEnabled", "syncAchievements", "syncPlaytime", "syncLuas"] { store.values[key] = property(key) }
    }
    func save() throws { try disk.write(config, to: disk.configURL) }
    func set(_ key: String, value: Any) async throws {
        let keys = ["providerName": "provider", "providerPath": "token_path", "syncFolderPath": "sync_folder_path", "notificationsEnabled": "notifications_enabled", "statsSyncEnabled": "stats_sync_enabled", "syncAchievements": "sync_achievements", "syncPlaytime": "sync_playtime", "syncLuas": "sync_luas"]
        guard let field = keys[key] else { throw AppError.message("Unknown setting: \(key)") }
        if key == "providerName" {
            guard let name = value as? String, ["local", "folder", "gdrive", "onedrive", "r2", "s3"].contains(name) else { throw AppError.message("Unknown cloud provider.") }
            var paths = config["token_paths"] as? [String: String] ?? [:]
            paths[provider] = tokenPath(provider); config["token_paths"] = paths
            config.removeValue(forKey: "token_path")
            remoteIDs = []; authenticated = false; store.cloudFiles = []; store.cloudAppID = 0
        }
        config[field] = value
        if key == "syncFolderPath" { config["sync_path"] = value }
        try save(); publish()
        if ["providerName", "providerPath", "syncFolderPath"].contains(key) { try await refreshStatus(); try await fetchRemote() }
    }
    func command(_ args: [String], input: Data? = nil) async throws -> NativeCommandResult { try await NativeCommand().run(cli, args, input: input) }
    func credentials(_ provider: String) async throws -> [String: Any] {
        let result = try await command(["read-credentials-path", tokenPath(provider)])
        guard result.status == 0 else { return [:] }
        return (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any] ?? [:]
    }
    func refreshStatus() async throws {
        let previousProvider = provider, previousAccount = account.id
        config = disk.json(disk.configURL); account = disk.account()
        let requestedProvider = provider, requestedAccount = account.id
        if previousProvider != provider || previousAccount != account.id { remoteIDs = []; store.cloudFiles = []; store.cloudAppID = 0 }
        if provider == "local" { authenticated = true }
        else if provider == "folder" { authenticated = FileManager.default.fileExists(atPath: property("syncFolderPath") as? String ?? "") }
        else {
            let available = !(try await credentials(requestedProvider)).isEmpty
            guard provider == requestedProvider, account.id == requestedAccount else { return }
            authenticated = available
        }
        rebuildGames(); publish()
        Task { await resolveNames(Set(store.games.map { number($0, "appId") })) }
    }
    func rebuildGames() {
        var records = disk.localGames(account: account.id, cache: cache)
        for index in records.indices { records[index]["isRemote"] = remoteIDs.contains(number(records[index], "appId")) }
        let local = Set(records.map { number($0, "appId") })
        for id in remoteIDs.subtracting(local) {
            records.append(["appId": id, "name": gameName(id), "fileCount": 0, "totalSize": 0, "sizeFormatted": "0 B", "isLocal": false, "isRemote": true, "headerUrl": cache[String(id)]?["headerUrl"] as? String ?? "https://shared.steamstatic.com/store_item_assets/steam/apps/\(id)/header.jpg"])
        }
        store.games = records.filter { !string($0, "name").localizedCaseInsensitiveContains("Soundtrack") }
        store.cloudGames = store.games.filter { remoteIDs.contains(number($0, "appId")) && gameName(number($0, "appId")) != "Unknown game" }.map { var row = $0; row["label"] = gameName(number(row, "appId")); return row }
        publish()
    }
    func gameName(_ id: Int) -> String { cache[String(id)]?["name"] as? String ?? "Unknown game" }
    func resolveNames(_ ids: Set<Int>) async {
        pendingNameIDs.formUnion(ids)
        guard !resolvingNames else { return }
        let missing = pendingNameIDs.filter { cache[String($0)]?["name"] == nil }
        pendingNameIDs = []
        guard !missing.isEmpty else { return }
        resolvingNames = true
        defer {
            resolvingNames = false
            if !pendingNameIDs.isEmpty { Task { await resolveNames([]) } }
        }
        // Prefer installed manifests before asking Steam's public store service.
        let libraries = SteamKeyValues.parse(disk.text(disk.steam.appendingPathComponent("steamapps/libraryfolders.vdf")))["libraryfolders"] as? [String: [String: Any]] ?? [:]
        let roots = [disk.steam] + libraries.values.compactMap { ($0["path"] as? String).map { URL(fileURLWithPath: $0) } }
        for id in missing {
            for root in roots {
                let manifest = SteamKeyValues.parse(disk.text(root.appendingPathComponent("steamapps/appmanifest_\(id).acf")))["AppState"] as? [String: Any] ?? [:]
                if let name = manifest["name"] as? String, !name.isEmpty { cache[String(id)] = ["name": name]; break }
            }
        }
        let unresolved = missing.filter { cache[String($0)] == nil }
        if !unresolved.isEmpty {
            let payload: [String: Any] = ["ids": unresolved.map { ["appid": $0] }, "context": ["language": "english", "country_code": "US"], "data_request": ["include_basic_info": true, "include_assets": true]]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                var url = URLComponents(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1")!
                url.queryItems = [URLQueryItem(name: "input_json", value: String(decoding: data, as: UTF8.self))]
                if let target = url.url, let (body, response) = try? await URLSession.shared.data(from: target), (response as? HTTPURLResponse)?.statusCode == 200,
                   let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let items = (json["response"] as? [String: Any])?["store_items"] as? [[String: Any]] {
                    for item in items {
                        let id = number(item, "appid"), name = string(item, "name")
                        if id > 0, !name.isEmpty { cache[String(id)] = ["name": name] }
                    }
                }
            }
        }
        try? disk.write(cache, to: disk.root.appendingPathComponent("store_cache.json")); rebuildGames()
    }
    func fetchRemote() async throws {
        guard !fetchingRemote, authenticated, provider != "local", !account.id.isEmpty else { return }
        fetchingRemote = true; defer { fetchingRemote = false }
        let requestedProvider = provider, requestedAccount = account.id
        if requestedProvider == "folder" {
            let directory = URL(fileURLWithPath: property("syncFolderPath") as? String ?? "").appendingPathComponent(requestedAccount)
            remoteIDs = Set(disk.directories(directory).compactMap { Int($0.lastPathComponent) }.filter { $0 > 0 && ![7, 760, 2371090].contains($0) })
            rebuildGames(); await resolveNames(remoteIDs); return
        }
        let result = try await command(["list-remote-app-ids", requestedProvider, requestedAccount]).json()
        guard provider == requestedProvider, account.id == requestedAccount else { return }
        remoteIDs = Set((result["app_ids"] as? [String] ?? []).compactMap(Int.init).filter { $0 > 0 && ![7, 760, 2371090].contains($0) })
        rebuildGames(); await resolveNames(remoteIDs)
    }
    func checkDeployment() async {
        let installed = FileManager.default.fileExists(atPath: RuntimeInstaller.runtime.path)
        store.deploy = ["slssteamInstalled": FileManager.default.fileExists(atPath: RuntimeInstaller.steam.path), "alreadyDeployed": installed, "updateAvailable": false, "statusMessage": ""]
        do {
            let current = installed ? try await Task.detached { try RuntimeContent.current() }.value : false
            store.deploy["updateAvailable"] = installed && !current
        } catch { store.deploy["statusMessage"] = "Could not compare installed files: \(error.localizedDescription)" }
        publish()
    }
    func invoke(_ method: String, args: [Any], target: String) async throws -> Any? {
        if target == "deployer" {
            if method == "checkPrerequisites" { await checkDeployment(); return nil }
            if ["deploy", "update", "undeploy", "purgeAll"].contains(method) {
                if ["deploy", "update"].contains(method) { _ = try await command(["diagnose"]).json() }
                try await Task.detached { try RuntimeInstaller.install(["deploy", "update"].contains(method)) }.value
                if method == "purgeAll" {
                    let result = try await command(["purge-credentials"])
                    guard result.status == 0 else { throw AppError.message("Could not remove credentials. Local data was retained.") }
                    try FileManager.default.removeItem(at: disk.root)
                }
                await checkDeployment(); return true
            }
        }
        switch method {
        case "refreshStatus": try await refreshStatus()
        case "saveConfig": try save()
        case "getAppDetails": return store.games
        case "cloudGames": return store.cloudGames
        case "getAppName": return gameName(args.first as? Int ?? 0)
        case "fetchRemoteApps": try await fetchRemote()
        case "defaultTokenPath": return tokenPath(args.first as? String ?? provider)
        case "managedIDs": return (config["apps"] as? [Int] ?? []).map(String.init).joined(separator: ", ")
        case "redirectEnabled": return config["enabled"] as? Bool ?? false
        case "saveManagedIDs":
            let tokens = (args.first as? String ?? "").split { $0 == "," || $0.isWhitespace }
            guard tokens.allSatisfy({ Int($0).map { $0 > 0 && $0 <= 0xffffff } ?? false }) else { throw AppError.message("Invalid game ID.") }
            config["apps"] = Array(Set(tokens.compactMap { Int($0) })).sorted(); config["enabled"] = args.count > 1 ? args[1] as? Bool ?? false : false
            try save(); return "Settings saved. Restart Steam to apply."
        case "manifestSettings": return manifestSettings()
        case "manifestApps": return manifestApps()
        case "saveManifestSettings":
            guard args.count == 3 else { throw AppError.message("Invalid manifest settings.") }
            config["manifest_pinning"] = args[0]; config["auto_comment"] = args[1]; config["pinned_apps"] = args[2]
            try save(); return "Manifest settings saved. Restart Steam to apply."
        case "scanOrphans": return scanOrphans()
        case "listBackups": return listBackups()
        case "restoreBackup": return try restoreBackup(args.first as? String ?? "")
        case "deleteBackup": try deleteBackup(args.first as? String ?? "")
        case "deleteAppData": try await deleteAppData(args.first as? Int ?? 0)
        case "getR2Credentials", "getS3Credentials":
            var result = try await credentials(method == "getR2Credentials" ? "r2" : "s3")
            result["has_secret"] = !(result["secret_access_key"] as? String ?? "").isEmpty
            result.removeValue(forKey: "secret_access_key"); return result
        case "saveR2Credentials", "saveS3Credentials": return try await saveCredentials(method == "saveR2Credentials" ? "r2" : "s3", args: args)
        case "testProviderConnection":
            store.providerBusy = true; defer { store.providerBusy = false }
            let name = args.first as? String ?? provider
            _ = try await command(["list-remote-app-ids", name, account.id.isEmpty ? "0" : account.id]).json()
            store.status = "Connected. Credentials saved."; try await refreshStatus(); try await fetchRemote(); return true
        case "startAuth":
            guard args.count == 2, let name = args[0] as? String, ["gdrive", "onedrive"].contains(name), let path = args[1] as? String else { throw AppError.message("Invalid sign-in provider.") }
            store.providerBusy = true; defer { store.providerBusy = false }
            let tokens = try await OAuth.authorize(name)
            let result = try await command(["store-credentials-path", path], input: tokens)
            guard result.status == 0 else { throw AppError.message("Could not save credentials in Keychain.") }
            var paths = config["token_paths"] as? [String: String] ?? [:]; paths[name] = path; config["token_paths"] = paths
            try save(); store.status = "Connected successfully."; try await refreshStatus(); try await fetchRemote()
        case "cloudSaveList", "cloudSaveDelete", "steamCloudList", "steamCloudDelete": try await cloudFiles(method, args: args)
        case "scanProvider": try await scanProvider(args.first as? String ?? provider)
        case "startMigration":
            guard args.count == 2, let source = args[0] as? String, let destination = args[1] as? String, source != destination else { throw AppError.message("Choose different cloud providers.") }
            try await migrate(source, destination)
        case "cancelMigration": migrationCommand?.cancel()
        default: throw AppError.message("Unknown native operation: \(method)")
        }
        return nil
    }
}
