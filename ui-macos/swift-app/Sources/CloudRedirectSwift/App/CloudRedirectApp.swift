import SwiftUI

@main struct CloudRedirectApp: App {
    @StateObject private var backend = BackendStore()
    var body: some Scene {
        WindowGroup("CloudRedirect") { ContentView(backend: backend).frame(minWidth: 940, minHeight: 640).tint(Color.accentColor) }
            .defaultSize(width: 1160, height: 780)
            .windowStyle(.hiddenTitleBar)
            .commands { CommandGroup(after: .toolbar) { Button("Refresh") { backend.refresh() }.keyboardShortcut("r") } }
    }
}
