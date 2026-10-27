import SwiftUI

struct SetupView: View {
    @ObservedObject var backend: BackendStore
    @State private var removeRuntime = false
    @State private var purge = false
    @State private var countdown = 5
    private var installed: Bool { backend.deploy["alreadyDeployed"] as? Bool == true }
    private var updateAvailable: Bool { backend.deploy["updateAvailable"] as? Bool == true }
    var body: some View {
        PageLayout(title: "Setup", subtitle: "Manage Steam integration and cloud save redirection.") {
            Text("Steam integration").font(.headline)
            Panel {
                SettingLine(title: installed ? "Installed in Steam" : "CloudRedirect is not installed", detail: installed ? (updateAvailable ? "A runtime update is available." : "Up to date") : "Install the runtime used by Steam.") {
                    HStack(spacing: 8) {
                        if installed {
                            if updateAvailable { ActionButton(title: "Update", primary: true) { perform("update") } }
                            ActionButton(title: "Remove") { removeRuntime = true }
                        } else { ActionButton(title: "Install", primary: true) { perform("deploy") } }
                    }
                }
                if let message = backend.deploy["statusMessage"] as? String, !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Managed games").font(.headline)
            Panel {
                SettingLine(title: "Cloud save redirection", detail: "Use CloudRedirect for your managed games.") { Toggle("Cloud save redirection", isOn: $backend.redirectEnabled).labelsHidden().accessibilityLabel("Cloud save redirection").toggleStyle(.switch).tint(sage) }
                Divider()
                VStack(alignment: .leading, spacing: 6) { Text("Additional game IDs").fontWeight(.medium); TextField("620, 848450, …", text: $backend.managedIDs).textFieldStyle(RoundedInputStyle()); Text("Optional. Games in macSteam and self-unlocking Lua scripts are included automatically.").font(.caption).foregroundStyle(.secondary) }
                HStack { Text(backend.status).font(.caption).foregroundStyle(.secondary); Spacer(); ActionButton(title: "Save Changes", primary: true) { backend.call("saveManagedIDs", [backend.managedIDs, backend.redirectEnabled]) { backend.status = $0 as? String ?? "" } } }
            }
            Text("Restart Steam after changing runtime or managed games.").font(.caption).foregroundStyle(.secondary)
            Text("Reset").font(.headline)
            Panel { SettingLine(title: "Remove CloudRedirect data", detail: "Remove the runtime, credentials, settings, and local data.") { ActionButton(title: "Remove All Data…") { countdown = 5; purge = true } } }
        }.onAppear { backend.loadSetup() }
        .confirmationDialog("Remove the runtime from Steam?", isPresented: $removeRuntime) { Button("Remove Runtime", role: .destructive) { perform("undeploy") }; Button("Cancel", role: .cancel) {} } message: { Text("Your saves and settings are retained.") }
        .sheet(isPresented: $purge) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Remove All Data").font(.title2.bold())
                Text("This removes the runtime, credentials, settings, local cached saves, logs, and backups. Cloud provider files are retained.").fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Cancel") { purge = false }; Button(countdown > 0 ? "Remove (\(countdown))" : "Remove All Data", role: .destructive) { perform("purgeAll"); purge = false }.disabled(countdown > 0) }.controlSize(.regular)
            }.padding(24).frame(width: 450).task { while countdown > 0 && !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); countdown -= 1 } }
        }
    }
    private func perform(_ operation: String) { backend.call(operation, target: "deployer") { _ in backend.refreshDeployment(); backend.refreshProperties() } }
}

struct StatsView: View {
    @ObservedObject var backend: BackendStore
    var body: some View {
        PageLayout(title: "Stats & Scripts", subtitle: "Bring achievements, playtime, and Lua scripts across devices.") {
            Text("Game activity").font(.headline)
            Panel {
                toggle("Sync game activity", "Use your configured cloud provider.", "statsSyncEnabled")
                Divider(); toggle("Achievements", "Sync unlocked achievements for managed games.", "syncAchievements").disabled(!backend.bool("statsSyncEnabled"))
                Divider(); toggle("Playtime", "Merge game sessions across devices.", "syncPlaytime").disabled(!backend.bool("statsSyncEnabled"))
            }
            Text("Achievement and playtime sync are experimental. Keep a backup of your data.").font(.caption).foregroundStyle(.secondary)
            Text("Lua scripts").font(.headline)
            Panel { toggle("Sync scripts", "Merge Lua scripts with the cloud archive. Existing scripts are kept.", "syncLuas") }
            Text("Restart Steam after changing sync settings.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func toggle(_ title: String, _ detail: String, _ key: String) -> some View {
        SettingLine(title: title, detail: detail) { Toggle(title, isOn: Binding(get: { backend.bool(key) }, set: { backend.set(key, $0) })).labelsHidden().accessibilityLabel(title).toggleStyle(.switch).tint(sage) }
    }
}
