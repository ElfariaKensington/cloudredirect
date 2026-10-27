import SwiftUI

struct ManifestView: View {
    @ObservedObject var backend: BackendStore
    @State private var enabled = false
    @State private var autoComment = true
    @State private var initialized = false
    @State private var selected: Set<Int> = []
    var body: some View {
        PageLayout(title: "Manifest Pins", subtitle: "Manage depot manifest pins in your Lua scripts.") {
            Panel {
                SettingLine(title: "Manifest pinning", detail: "Apply the pinned manifests from selected scripts.") { Toggle("Manifest pinning", isOn: $enabled).labelsHidden().accessibilityLabel("Manifest pinning").toggleStyle(.switch).tint(sage).onChange(of: enabled) { _, _ in persist() } }
                Divider()
                SettingLine(title: "Selected games only", detail: "Ignore manifest pins from unselected Lua scripts.") { Toggle("Selected games only", isOn: $autoComment).labelsHidden().accessibilityLabel("Selected games only").toggleStyle(.switch).tint(sage).onChange(of: autoComment) { _, _ in persist() } }
            }
            HStack { Text("Games").font(.headline); Spacer(); ActionButton(title: "Lua Folder…") { backend.get("steamPath") { value in if let path = value as? String { let url = URL(fileURLWithPath: path).appendingPathComponent("config/stplug-in"); try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); NSWorkspace.shared.open(url) } } }; ActionButton(title: "Refresh") { backend.loadManifest() } }
            Panel(spacing: 8) {
                if backend.manifestGames.isEmpty { Text("No Lua scripts found").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100) }
                else { ForEach(backend.manifestGames, id: \.gameID) { game in
                    let id = number(game, "appId")
                    Toggle(isOn: Binding(get: { selected.contains(id) }, set: { value in if value { selected.insert(id) } else { selected.remove(id) }; persist() })) { Text("\(string(game, "name")) · \(number(game, "pins")) depot pins") }.toggleStyle(.checkbox).tint(sage)
                } }
            }
            Text(backend.status.isEmpty ? "Changes are saved automatically. Restart Steam to apply them." : backend.status).font(.caption).foregroundStyle(.secondary)
        }.onAppear { initialized = false; backend.loadManifest() }
        .onReceive(backend.$manifestSettings) { settings in
            guard !settings.isEmpty else { return }; initialized = false
            enabled = settings["enabled"] as? Bool ?? false; autoComment = settings["autoComment"] as? Bool ?? true
            selected = Set((settings["pinnedApps"] as? [NSNumber] ?? []).map(\.intValue)); DispatchQueue.main.async { initialized = true }
        }
    }
    private func persist() { guard initialized else { return }; backend.call("saveManifestSettings", [enabled, autoComment, selected.sorted()]) { backend.status = $0 as? String ?? "" } }
}
private extension Dictionary where Key == String, Value == Any {
    var gameID: Int { number(self, "appId") }
}

struct MigrationView: View {
    @ObservedObject var backend: BackendStore
    @State private var source = "gdrive"
    @State private var destination = "onedrive"
    @State private var confirming = false
    @State private var selectedCloudData: String?
    private let options = providers.filter { ["gdrive", "onedrive", "r2", "s3"].contains($0.0) }
    var body: some View {
        PageLayout(title: "Migration", subtitle: "Move cloud data between providers.") {
            Panel {
                HStack(alignment: .controlCenter) {
                    ChoiceMenu(title: "From", selection: $source, options: options)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    ChoiceMenu(title: "To", selection: $destination, options: options)
                }.disabled(backend.migrationBusy)
                HStack { ActionButton(title: "Scan Source") { selectedCloudData = nil; backend.call("scanProvider", [source]) }.disabled(backend.migrationBusy || source == destination); Spacer(); ActionButton(title: "Migrate…", primary: true) { confirming = true }.disabled(backend.migrationBusy || source == destination || !backend.migrationScanned || backend.migrationApps.isEmpty) }
                if source == destination { Text("Source and destination must be different providers.").foregroundStyle(.secondary).font(.caption) }
            }
            if backend.migrationBusy { HStack { ProgressView().controlSize(.small); Text(backend.migrationStatus); Spacer(); ActionButton(title: "Cancel") { backend.call("cancelMigration") } } }
            else if !backend.migrationStatus.isEmpty { Text(backend.migrationStatus).foregroundStyle(.secondary).font(.caption) }
            if backend.migrationScanned {
                Text("Cloud data").font(.headline)
                Panel(spacing: 2) {
                    if backend.migrationApps.isEmpty {
                        Text("No cloud data found on the source provider.").foregroundStyle(.secondary)
                    } else {
                        MigrationCloudList(
                            items: backend.migrationApps.map { app in
                                let appID = number(app, "appId")
                                let accountID = string(app, "accountId")
                                let name = backend.games.first(where: { number($0, "appId") == appID }).map { string($0, "name") } ?? "Unknown game"
                                return MigrationCloudRow(id: "\(appID)/\(accountID)", name: name)
                            },
                            selection: $selectedCloudData
                        )
                        .frame(height: CGFloat(min(backend.migrationApps.count, 8) * 32))
                    }
                }
            }
        }
        .onChange(of: source) { _, _ in backend.migrationScanned = false; backend.migrationApps = []; selectedCloudData = nil }
        .onChange(of: destination) { _, _ in backend.migrationScanned = false; backend.migrationApps = []; selectedCloudData = nil }
        .confirmationDialog("Migrate cloud data?", isPresented: $confirming) { Button("Start Migration") { backend.call("startMigration", [source, destination]) }; Button("Cancel", role: .cancel) {} } message: { Text("Copy cloud data from \(providerName(source)) to \(providerName(destination)).") }
    }
}
