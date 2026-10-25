import AppKit
import Foundation
import SwiftUI

@MainActor final class Settings: ObservableObject {
    @Published var provider = "folder"
    @Published var folder = ""
    @Published var gameIDs = ""
    @Published var enabled = false
    @Published var busy = false
    @Published var message = "Choose storage and game IDs, save settings, then install the runtime."
    @Published var runtimeStatus = "Not installed"
    @Published var showCredentials = false
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CloudRedirect", isDirectory: true)
    static var config: URL { root.appendingPathComponent("config.json") }
    init() {
        if let data = try? Data(contentsOf: Self.config), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            provider = value["provider"] as? String ?? "folder"
            folder = value["sync_path"] as? String ?? ""
            gameIDs = (value["apps"] as? [Int] ?? []).map(String.init).joined(separator: ", ")
            enabled = value["enabled"] as? Bool ?? false
        }
        refresh()
    }
    func ids() throws -> [Int] {
        let parts = gameIDs.split(whereSeparator: { $0 == "," || $0.isWhitespace })
        var result = Set<Int>()
        for part in parts {
            guard let number = Int(part), number > 0, number <= 0xffffff else { throw AppError.message("Enter Steam game IDs separated by commas, for example 620, 20.") }
            result.insert(number)
        }
        return result.sorted()
    }
    func save() throws {
        let apps = try ids()
        if enabled && apps.isEmpty { throw AppError.message("Select at least one game ID before enabling redirection.") }
        if provider == "folder" {
            guard folder.hasPrefix("/") else { throw AppError.message("Choose an absolute sync folder.") }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &directory), directory.boolValue,
                  FileManager.default.isWritableFile(atPath: folder) else { throw AppError.message("Choose an existing, writable sync folder.") }
            let destination = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
            let local = Self.root.resolvingSymlinksInPath().path
            guard destination != local, !destination.hasPrefix(local + "/"), !local.hasPrefix(destination + "/") else { throw AppError.message("Choose a sync folder separate from CloudRedirect's local cache.") }
        }
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var value = ((try? Data(contentsOf: Self.config)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        value["provider"] = provider; value["sync_path"] = folder; value["apps"] = apps; value["enabled"] = enabled
        value["stats_sync_enabled"] = false
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.config.path)
    }
    func refresh() {
        guard FileManager.default.fileExists(atPath: RuntimeInstaller.runtime.path) else { runtimeStatus = "Not installed"; return }
        runtimeStatus = "Installed · restart Steam to apply settings"
        if let data = try? Data(contentsOf: Self.root.appendingPathComponent("runtime-status.json")),
           let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let pid = status["pid"] as? Int32,
           NSWorkspace.shared.runningApplications.contains(where: { $0.processIdentifier == pid && $0.executableURL?.lastPathComponent == "steam_osx" }) {
            runtimeStatus = status["message"] as? String ?? runtimeStatus
        }
    }
    func perform(_ label: String, action: @escaping () throws -> String) {
        busy = true; message = label
        Task {
            do { message = try await Task.detached(priority: .userInitiated) { try action() }.value }
            catch { message = error.localizedDescription }
            busy = false; refresh()
        }
    }
    func saveSettings() {
        do { try save(); message = "Settings saved. Restart Steam to apply changes." }
        catch { message = error.localizedDescription }
    }
    func check() {
        do { try save() } catch { message = error.localizedDescription; return }
        perform("Checking provider…") {
            _ = try RuntimeInstaller.run(RuntimeInstaller.helper, ["check-provider"])
            return "Provider initialized and credentials accepted. Remote access is checked when a game syncs."
        }
    }
    func install(_ install: Bool) {
        if install { do { try save() } catch { message = error.localizedDescription; return } }
        perform(install ? "Installing runtime…" : "Removing runtime…") {
            if install { _ = try RuntimeInstaller.run(RuntimeInstaller.helper, ["diagnose"]) }
            try RuntimeInstaller.install(install)
            return install ? "Runtime installed. Open Steam to start." : "Runtime removed. Your saves and settings are retained."
        }
    }
    func signIn() {
        let selected = provider; busy = true; message = "Complete sign-in in your browser. This window will update when finished."
        Task {
            do {
                let credentials = try await OAuth.authorize(selected)
                _ = try await Task.detached { try RuntimeInstaller.run(RuntimeInstaller.helper, ["store-credentials", selected], input: credentials) }.value
                message = "Signed in. Credentials saved in Keychain. Restart Steam after saving settings."
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Use Sync Folder"
        if panel.runModal() == .OK { folder = panel.url!.path }
    }
    func importCredentials() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_048_576, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let refresh = json["refresh_token"] as? String, !refresh.isEmpty else { throw AppError.message("Select OAuth token JSON containing a refresh_token.") }
            let selected = provider
            perform("Importing credentials into Keychain…") {
                _ = try RuntimeInstaller.run(RuntimeInstaller.helper, ["store-credentials", selected], input: data)
                return "Credentials imported into Keychain."
            }
        } catch { message = error.localizedDescription }
    }
}

struct CredentialsView: View {
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var access = ""
    @State private var secret = ""
    @State private var bucket = ""
    @State private var endpoint = ""
    @State private var region = "us-east-1"
    @State private var account = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(settings.provider == "r2" ? "Cloudflare R2 credentials" : "S3 credentials").font(.title2.bold())
            Form {
                TextField("Bucket", text: $bucket)
                TextField("Access key ID", text: $access)
                SecureField("Secret access key", text: $secret)
                if settings.provider == "r2" { TextField("Cloudflare account ID", text: $account) }
                else { TextField("Region", text: $region) }
                TextField("HTTPS endpoint (optional)", text: $endpoint)
            }
            Text("Credentials are stored in your login Keychain and shared with Steam's CloudRedirect runtime.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save in Keychain") { store() }.buttonStyle(.borderedProminent).disabled(access.isEmpty || secret.isEmpty || bucket.isEmpty || (settings.provider == "r2" && account.isEmpty)) }
        }.padding(24).frame(width: 500)
    }
    func store() {
        if !endpoint.isEmpty && !endpoint.hasPrefix("https://") { settings.message = "Use an https:// endpoint."; dismiss(); return }
        let selected = settings.provider
        let credentials = ["access_key_id": access, "secret_access_key": secret, "bucket": bucket, "region": region, "endpoint": endpoint, "account_id": account]
        guard let data = try? JSONSerialization.data(withJSONObject: credentials) else { return }
        settings.perform("Saving credentials…") {
            _ = try RuntimeInstaller.run(RuntimeInstaller.helper, ["store-credentials", selected], input: data)
            return "Credentials saved in Keychain."
        }
        dismiss()
    }
}

struct ContentView: View {
    @StateObject private var settings = Settings()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "icloud.and.arrow.up").font(.system(size: 36)).foregroundStyle(.blue)
                VStack(alignment: .leading) { Text("CloudRedirect").font(.largeTitle.bold()); Text("Your Steam saves, your storage").foregroundStyle(.secondary) }
                Spacer()
                if settings.busy { ProgressView().controlSize(.small) }
            }
            GroupBox("Storage") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Provider", selection: $settings.provider) {
                        Text("Sync folder").tag("folder"); Text("Google Drive").tag("gdrive"); Text("OneDrive").tag("onedrive"); Text("Amazon S3 / compatible").tag("s3"); Text("Cloudflare R2").tag("r2"); Text("Local cache only").tag("local")
                    }
                    if settings.provider == "folder" {
                        HStack { TextField("Choose a folder on a disk or synced drive", text: $settings.folder); Button("Choose…", action: settings.chooseFolder) }
                        Text("Choose a dedicated folder in iCloud Drive, a mounted drive, or another sync service.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if settings.provider == "gdrive" || settings.provider == "onedrive" {
                        HStack { Button("Sign In in Browser", action: settings.signIn); Button("Import Token JSON…", action: settings.importCredentials) }
                    } else if settings.provider != "local" { Button("Configure Credentials…") { settings.showCredentials = true } }
                    Button("Check Provider", action: settings.check)
                }.padding(8)
            }
            GroupBox("Games") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Steam app IDs, e.g. 620, 20", text: $settings.gameIDs)
                    Text("Only these games use redirection. Games need existing Steam Cloud / AutoCloud rules; this port does not create missing rules.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Enable cloud save redirection", isOn: $settings.enabled)
                }.padding(8)
            }
            HStack { Button("Save Settings", action: settings.saveSettings).buttonStyle(.borderedProminent); Spacer(); Button("Check Steam Compatibility") {
                settings.perform("Checking ARM64 Steam interfaces…") {
                    let raw = try RuntimeInstaller.run(RuntimeInstaller.helper, ["diagnose"])
                    let value = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
                    return value?["message"] as? String ?? raw
                }
            } }
            Divider()
            Text(settings.runtimeStatus).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Install Runtime") { settings.install(true) }
                Button("Remove Runtime") { settings.install(false) }
                Button("Open Steam") { NSWorkspace.shared.open(RuntimeInstaller.steam) }
                Spacer()
                Button("Logs") { try? FileManager.default.createDirectory(at: Settings.root, withIntermediateDirectories: true); NSWorkspace.shared.open(Settings.root) }
                Button { settings.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh runtime status")
            }
            Text(settings.message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }.padding(28).frame(width: 680).disabled(settings.busy)
            .sheet(isPresented: $settings.showCredentials) { CredentialsView(settings: settings) }
    }
}

@main struct CloudRedirectApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }.windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
