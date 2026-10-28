import SwiftUI
import UniformTypeIdentifiers

@main
struct SignDockApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var importer = ImportQueue()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(importer)
                .onOpenURL { url in
                    // "Open in SignDock" from Files/Safari/other apps.
                    if url.isFileURL { importer.enqueue(files: [url], store: store) }
                }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            LibraryView().tabItem { Label("Library", systemImage: "square.stack.3d.up") }
            HistoryView().tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            CertificatesView().tabItem { Label("Certificates", systemImage: "key") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

extension UTType {
    static let ipa = UTType("com.apple.itunes.ipa") ?? UTType(filenameExtension: "ipa") ?? .data
}
