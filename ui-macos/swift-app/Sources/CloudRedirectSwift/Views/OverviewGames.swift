import SwiftUI

struct OverviewView: View {
    @ObservedObject var backend: BackendStore
    var navigate: (Destination) -> Void
    var body: some View {
        PageLayout(title: "Your saves, together.", subtitle: "Manage game saves and sync across your devices.") {
            Panel { HStack(spacing: 18) {
                Image(systemName: "icloud").font(.system(size: 38)).foregroundStyle(sageIcon)
                VStack(alignment: .leading, spacing: 5) {
                    Text(backend.text("providerName") == "local" ? "Choose where your saves live" : providerName(backend.text("providerName"))).font(.headline)
                    Text(backend.bool("providerAuthenticated") ? "Connected and ready to sync" : "Connect a cloud provider or folder to get started.").foregroundStyle(.secondary)
                }; Spacer(); ActionButton(title: "Manage…") { navigate(.provider) }
            } }
            HStack(spacing: 14) {
                metric("On this Mac", backend.count("managedAppCount"), "games with local saves", "internaldrive")
                metric("In the cloud", backend.count("remoteOnlyAppCount"), "games available to restore", "cloud")
            }
            Text("Steam integration").font(.headline)
            Panel { SettingLine(title: backend.bool("deployed") ? "Installed in Steam" : "Set up CloudRedirect", detail: "Manage the runtime and the games you want to sync.") { ActionButton(title: "Open Setup…") { navigate(.setup) } } }
            Text("Preferences").font(.headline)
            Panel { SettingLine(title: "Launch notifications", detail: "Notify when CloudRedirect loads in Steam.") { Toggle("Launch notifications", isOn: Binding(get: { backend.bool("notificationsEnabled") }, set: { backend.set("notificationsEnabled", $0) })).labelsHidden().accessibilityLabel("Launch notifications").toggleStyle(.switch).tint(sage) } }
            HStack { ActionButton(title: "Open Log…") { openLog() }; ActionButton(title: "Configuration Folder…") { openConfig() } }
        }
    }
    private func metric(_ label: String, _ count: Int, _ detail: String, _ icon: String) -> some View {
        Panel { HStack { Text(label).foregroundStyle(.secondary); Spacer(); Image(systemName: icon).foregroundStyle(sageIcon) }; Text("\(count)").font(.system(size: 32, weight: .light)); Text(detail).font(.caption).foregroundStyle(.secondary) }
    }
}
func openConfig() { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CloudRedirect")) }
func openLog() { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CloudRedirect/cloud_redirect.log")) }

struct GamesView: View {
    @ObservedObject var backend: BackendStore
    @State private var search = ""
    @State private var pendingDelete: Int?
    @State private var selectedGame: Int?
    private var rows: [[String: Any]] {
        backend.games.filter { (number($0, "fileCount") > 0 || ($0["isRemote"] as? Bool == true)) && (search.isEmpty || string($0, "name").localizedCaseInsensitiveContains(search)) }.sorted { string($0, "name").localizedCaseInsensitiveCompare(string($1, "name")) == .orderedAscending }
    }
    var body: some View {
        PageLayout(title: "Games", subtitle: "Games with saved data on this Mac or in your cloud provider.") {
            HStack { TextField("Search games", text: $search).textFieldStyle(RoundedInputStyle()); ActionButton(title: "Scan Orphans") { backend.call("scanOrphans") { result in
                let rows = result as? [[String: Any]] ?? []
                backend.orphanMessage = rows.isEmpty ? "No unused cloud blobs were found." : rows.map { "\(string($0, "name")): \(number($0, "orphanCount")) files · \(string($0, "orphanSizeFormatted"))" }.joined(separator: "\n")
                backend.showOrphans = true
            } }; ActionButton(title: "Refresh") { backend.call("fetchRemoteApps"); backend.refresh() } }
            if rows.isEmpty { ContentUnavailableView("No saved games found", systemImage: "gamecontroller", description: Text("Games with local or cloud saves will appear here.")) }
            else {
                Panel(spacing: 2) {
                    GamesList(items: rows.map(GameListItem.init), selection: $selectedGame) { pendingDelete = $0 }
                        .frame(height: CGFloat(rows.count * 80))
                }
            }
        }
        .onAppear { backend.fetchRemote(); backend.refreshGames() }
        .alert("Storage scan", isPresented: $backend.showOrphans) { Button("Done", role: .cancel) {} } message: { Text(backend.orphanMessage) }
        .confirmationDialog("Delete game saves?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete All Saves", role: .destructive) { if let id = pendingDelete { backend.call("deleteAppData", [id]) { _ in backend.refresh(); backend.loadBackups() } }; pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("Local and cloud saves for this game will be deleted. A local backup is created first.") }
    }
}
