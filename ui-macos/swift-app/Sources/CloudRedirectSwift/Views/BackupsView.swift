import SwiftUI

struct BackupsView: View {
    @ObservedObject var backend: BackendStore
    @State private var pendingDelete: String?
    @State private var pendingRestore: String?
    @State private var busy = false
    @State private var result = ""
    private var backups: [[String: Any]] {
        backend.backups.sorted { string($0, "timestamp") > string($1, "timestamp") }
    }
    var body: some View {
        PageLayout(title: "Backups", subtitle: "Local recovery copies of your game saves.") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On this Mac").font(.headline)
                    Text(backups.isEmpty ? "Recovery copies appear here automatically." : "\(backups.count) backups · \(totalSize)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ActionButton(title: "Refresh") { backend.loadBackups() }.disabled(busy)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if backups.isEmpty {
                Panel {
                    HStack(alignment: .center, spacing: 20) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 30, weight: .light)).foregroundStyle(sageIcon)
                            .frame(width: 70, height: 70)
                            .background(sage.opacity(0.2), in: RoundedRectangle(cornerRadius: 18))
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No backups yet").font(.headline)
                            Text("CloudRedirect creates a recovery copy before removing game saves. You can restore those copies here.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Panel(spacing: 10) {
                    ForEach(backups, id: \.backupPath) { backup in
                        backupRow(backup)
                        if string(backup, "path") != string(backups.last ?? [:], "path") {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
            }
            if !result.isEmpty {
                Label(result, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .onAppear { backend.loadBackups() }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
            Button("Restore Backup") {
                guard let path = pendingRestore else { return }; pendingRestore = nil; busy = true
                backend.call("restoreBackup", [path]) { value in result = value as? String ?? ""; busy = false; backend.loadBackups() }
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: { Text("Matching local save files will be replaced with this recovery copy.") }
        .confirmationDialog("Delete this backup?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete Backup", role: .destructive) {
                guard let path = pendingDelete else { return }; pendingDelete = nil; busy = true
                backend.call("deleteBackup", [path]) { _ in busy = false; backend.loadBackups() }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("This removes only the selected local recovery copy.") }
    }
    private var totalSize: String {
        ByteCountFormatter.string(fromByteCount: backups.reduce(0) { $0 + Int64(number($1, "totalSize")) }, countStyle: .file)
    }
    private func backupRow(_ backup: [String: Any]) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "archivebox")
                .font(.system(size: 22, weight: .light)).foregroundStyle(sageIcon)
                .frame(width: 52, height: 52)
                .background(sage.opacity(0.15), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 5) {
                Text(backend.backupNames[number(backup, "appId")] ?? "Game backup").fontWeight(.semibold)
                Text(timestamp(string(backup, "timestamp"))).font(.caption).foregroundStyle(.secondary)
                Text("\(number(backup, "fileCount")) files · \(string(backup, "sizeFormatted"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            ActionButton(title: "Restore…") { pendingRestore = string(backup, "path") }.disabled(busy)
            Button(role: .destructive) { pendingDelete = string(backup, "path") } label: {
                Image(systemName: "trash").font(.system(size: 15)).frame(width: 28, height: 28)
            }.buttonStyle(IconActionStyle()).disabled(busy).help("Delete backup").accessibilityLabel("Delete backup")
        }.padding(.vertical, 4)
    }
    private func timestamp(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { return value.isEmpty ? "Date unavailable" : value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private extension Dictionary where Key == String, Value == Any {
    var backupPath: String { string(self, "path") }
}
