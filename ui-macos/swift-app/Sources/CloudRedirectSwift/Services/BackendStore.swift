import AppKit
import Foundation
import Security
import SwiftUI

@MainActor final class BackendStore: ObservableObject {
    @Published var values: [String: Any] = [:]
    @Published var deploy: [String: Any] = [:]
    @Published var games: [[String: Any]] = []
    @Published var backupNames: [Int: String] = [:]
    @Published var providerBusy = false
    @Published var backups: [[String: Any]] = []
    @Published var cloudGames: [[String: Any]] = []
    @Published var cloudFiles: [[String: Any]] = []
    @Published var cloudStatus = "Choose a game to view its cloud saves."
    @Published var cloudBusy = false
    @Published var status = ""
    @Published var error = ""
    @Published var orphanMessage = ""
    @Published var showOrphans = false
    @Published var migrationApps: [[String: Any]] = []
    @Published var migrationStatus = ""
    @Published var migrationBusy = false
    @Published var migrationScanned = false
    @Published var manifestSettings: [String: Any] = [:]
    @Published var manifestGames: [[String: Any]] = []
    @Published var managedIDs = ""
    @Published var redirectEnabled = false
    @Published var cloudAppID: Int = 0
    @Published var cloudCommunity = false

    private lazy var native = NativeBackend(store: self)
    private var remoteRequested = false

    init(startup: Bool = true) { if startup { refresh() } }
    func call(_ method: String, _ args: [Any] = [], target: String = "backend", completion: ((Any?) -> Void)? = nil) {
        Task {
            do { let result = try await native.invoke(method, args: args, target: target); completion?(result) }
            catch { self.error = error.localizedDescription; completion?(nil) }
        }
    }
    func get(_ key: String, target: String = "backend", completion: @escaping (Any?) -> Void) {
        completion(target == "deployer" ? deploy[key] : native.property(key))
    }
    func set(_ key: String, _ value: Any) {
        Task { do { try await native.set(key, value: value) } catch { self.error = error.localizedDescription } }
    }
    func bool(_ key: String) -> Bool { (values[key] as? Bool) ?? false }
    func text(_ key: String) -> String { (values[key] as? String) ?? "" }
    func count(_ key: String) -> Int { (values[key] as? NSNumber)?.intValue ?? 0 }
    func refreshProperties() { native.publish() }
    func refreshDeployment() { Task { await native.checkDeployment() } }
    func refreshGames() { native.rebuildGames() }
    func refresh() {
        Task {
            do { try await native.refreshStatus(); await native.checkDeployment(); fetchRemote() }
            catch { self.error = error.localizedDescription }
        }
    }
    func fetchRemote() {
        guard !remoteRequested else { return }; remoteRequested = true
        Task {
            do { try await native.fetchRemote() }
            catch { status = "Could not refresh cloud games: \(error.localizedDescription)" }
            remoteRequested = false
        }
    }
    func loadBackups() {
        backups = native.listBackups()
        for id in Set(backups.map { number($0, "appId") }).filter({ $0 > 0 }) { backupNames[id] = native.gameName(id) }
    }
    func loadSetup() {
        managedIDs = (native.config["apps"] as? [Int] ?? []).map(String.init).joined(separator: ", ")
        redirectEnabled = native.config["enabled"] as? Bool ?? false
        refreshDeployment()
    }
    func loadManifest() { manifestSettings = native.manifestSettings(); manifestGames = native.manifestApps() }
    func loadCloudFiles() {
        let id = cloudCommunity ? 760 : cloudAppID
        guard id > 0 else { return }; cloudBusy = true; cloudFiles = []
        call(cloudCommunity ? "steamCloudList" : "cloudSaveList", [id])
    }
    func deleteCloudFiles(_ names: [String]) {
        let id = cloudCommunity ? 760 : cloudAppID
        guard id > 0, !names.isEmpty else { return }; cloudBusy = true
        call(cloudCommunity ? "steamCloudDelete" : "cloudSaveDelete", [id, names])
    }
    func disconnectProvider(_ provider: String) {
        guard ["gdrive", "onedrive"].contains(provider), !providerBusy else { return }
        providerBusy = true
        call("defaultTokenPath", [provider]) { [weak self] value in
            guard let self, let defaultPath = value as? String else { self?.providerBusy = false; return }
            let configured = self.text("providerPath")
            let path = configured.isEmpty ? defaultPath : configured
            Task {
                let result = await Task.detached {
                    ProviderCredentials.disconnect(path: path)
                }.value
                self.providerBusy = false
                if result == errSecSuccess {
                    self.status = "Disconnected."
                    self.cloudFiles = []; self.cloudGames = []
                    self.call("refreshStatus"); self.refreshProperties()
                } else {
                    self.error = result == errSecUnimplemented
                        ? "Update the CloudRedirect runtime in Setup before disconnecting this provider."
                        : "Could not disconnect: \(SecCopyErrorMessageString(result, nil) as String? ?? "Keychain error")"
                }
            }
        }
    }
    func signIn(_ provider: String) {
        call("defaultTokenPath", [provider]) { [weak self] path in
            guard let self, let defaultPath = path as? String else { return }
            let configured = self.text("providerPath")
            self.call("startAuth", [provider, configured.isEmpty ? defaultPath : configured], target: "oauth")
        }
    }
}
