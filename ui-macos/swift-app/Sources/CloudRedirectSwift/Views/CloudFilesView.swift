import SwiftUI
struct CloudFilesView: View {
    @ObservedObject var backend: BackendStore
    @State private var selected: Set<String> = []
    @State private var confirming = false
    var body: some View {
        PageLayout(title: "Cloud Files", subtitle: "Browse and manage files saved in your cloud provider.") {
            HStack(alignment: .controlCenter) {
                ChoiceMenu(title: "Storage", selection: $backend.cloudCommunity, options: [(false, providerName(backend.text("providerName"))), (true, "Steam Community")]).frame(width: 200).disabled(backend.cloudBusy)
                if !backend.cloudCommunity {
                    ChoiceMenu(title: "Game", selection: $backend.cloudAppID, options: [(0, backend.cloudGames.isEmpty ? "No cloud games found" : "Select a game")] + backend.cloudGames.map { (number($0, "appId"), string($0, "label")) })
                        .frame(maxWidth: .infinity).disabled(backend.cloudBusy)
                }
                ActionButton(title: "Refresh") { selected.removeAll(); backend.loadCloudFiles() }.disabled(backend.cloudBusy || (!backend.cloudCommunity && backend.cloudAppID == 0))
            }
            HStack { ActionButton(title: "Select All") { selected = Set(backend.cloudFiles.map { string($0, "name") }) }; ActionButton(title: "Clear Selection") { selected.removeAll() }; Button("Delete Selected…", role: .destructive) { confirming = true }.disabled(selected.isEmpty || backend.cloudBusy); Spacer(); if backend.cloudCommunity { ActionButton(title: "Steam Console…") { if let url = URL(string: "steam://open/console") { NSWorkspace.shared.open(url) } } } }
            Panel {
                if backend.cloudBusy { HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding() }
                else if backend.cloudFiles.isEmpty { Text("No files loaded").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 150) }
                else {
                    CloudFileList(files: backend.cloudFiles.map(CloudFileRow.init), selection: $selected)
                    .frame(height: min(420, max(180, CGFloat(backend.cloudFiles.count) * 30)))
                }
            }

            Text(backend.cloudStatus).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { backend.fetchRemote(); backend.refreshGames() }
        .onChange(of: backend.cloudAppID) { _, _ in selected.removeAll(); backend.cloudFiles = []; if backend.cloudAppID > 0 { backend.loadCloudFiles() } }
        .onChange(of: backend.cloudCommunity) { _, _ in selected.removeAll(); backend.cloudFiles = []; if backend.cloudCommunity || backend.cloudAppID > 0 { backend.loadCloudFiles() } }
        .confirmationDialog("Delete cloud files?", isPresented: $confirming) {
            Button("Delete \(selected.count) Files", role: .destructive) { let names = selected.sorted(); selected.removeAll(); backend.deleteCloudFiles(names) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The selected files will be deleted from \(backend.cloudCommunity ? "Steam Community" : providerName(backend.text("providerName"))). Close this game on all devices first.") }
    }
}
private extension Dictionary where Key == String, Value == Any { var gameID: Int { number(self, "appId") }; var fileID: String { string(self, "name") } }
