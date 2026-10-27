import SwiftUI

struct ContentView: View {
    @ObservedObject var backend: BackendStore
    @State private var selection: Destination = .overview
    @State private var sidebarVisible = true
    private let sidebarWidth: CGFloat = 270
    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
                .offset(x: sidebarVisible ? 0 : -sidebarWidth)
                .frame(width: sidebarVisible ? sidebarWidth : 0, alignment: .leading)
                .clipped()
                .accessibilityHidden(!sidebarVisible)
            detail
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(ModernControls())
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.smooth(duration: 0.24)) { sidebarVisible.toggle() }
                } label: {
                    Image(systemName: "sidebar.leading").frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                .accessibilityLabel(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            }
        }
        .alert("CloudRedirect", isPresented: Binding(get: { !backend.error.isEmpty }, set: { if !$0 { backend.error = "" } })) {
            Button("OK") { backend.error = "" }
        } message: { Text(backend.error) }
    }
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(["Library", "Sync", "Tools"], id: \.self) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                        VStack(spacing: 5) {
                            ForEach(Destination.allCases.filter { $0.section == section }) { destination in
                                SidebarItem(destination: destination, selected: selection == destination) { selection = destination }
                            }
                        }
                    }
                }
            }.padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 24)
        }
        .frame(maxHeight: .infinity)
        .background { Rectangle().fill(.regularMaterial).ignoresSafeArea(edges: .top) }
        .overlay(alignment: .trailing) { Rectangle().fill(.primary.opacity(0.08)).frame(width: 1) }
    }
    @ViewBuilder private var detail: some View {
        switch selection {
        case .overview: OverviewView(backend: backend, navigate: { selection = $0 })
        case .games: GamesView(backend: backend)
        case .backups: BackupsView(backend: backend)
        case .provider: ProviderView(backend: backend)
        case .setup: SetupView(backend: backend)
        case .stats: StatsView(backend: backend)
        case .migration: MigrationView(backend: backend)
        case .manifest: ManifestView(backend: backend)
        case .cloud: CloudFilesView(backend: backend)
        }
    }
}

private struct SidebarItem: View {
    let destination: Destination
    let selected: Bool
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: destination.symbol)
                    .font(.system(size: 17, weight: selected ? .semibold : .regular))
                    .frame(width: 24).foregroundStyle(selected ? Color.black : sageIcon)
                Text(destination.rawValue).font(.system(size: 14, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.black : Color.primary)
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 44)
            .background(selected ? sage : Color.primary.opacity(hovered ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).frame(maxWidth: .infinity).contentShape(Rectangle()).onHover { hovered = $0 }
        .accessibilityLabel(destination.rawValue)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
