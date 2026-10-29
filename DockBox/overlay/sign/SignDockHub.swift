import SwiftUI

/// The signing half of the app, as one tab with four sections.
@available(iOS 16.0, *)
struct SignDockHub: View {
    enum HubSection: String, CaseIterable, Identifiable {
        case library = "Library", history = "History", certificates = "Certificates", cloud = "Cloud"
        var id: String { rawValue }
    }

    @StateObject private var store = AppStore()
    @StateObject private var importer = ImportQueue()
    @StateObject private var cloud = Cloud()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("backupIPAs") private var backupIPAs = true
    @State private var section = HubSection.library

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(HubSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch section {
            case .library: LibraryView()
            case .history: HistoryView()
            case .certificates: CertificatesView()
            case .cloud: CloudView()
            }
        }
        .environmentObject(store)
        .environmentObject(importer)
        .environmentObject(cloud)
        .onChange(of: scenePhase) { phase in
            // Sync when the app comes forward and when it's about to leave.
            if phase == .active || phase == .background, cloud.signedIn {
                Task { await cloud.syncNow(store: store, backupIPAs: backupIPAs) }
            }
        }
        .onOpenURL { url in
            // IPA files opened in the app land in the library as well as in the container flow.
            if url.isFileURL, url.pathExtension.lowercased() == "ipa" {
                importer.enqueue(files: [url], store: store)
            }
        }
    }
}

@available(iOS 16.0, *)
struct CloudView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationStack {
            Form {
                AccountView()
                Section("Storage") {
                    LabeledContent("Library", value: ByteCountFormatter.string(
                        fromByteCount: store.library.reduce(0) { $0 + $1.size }, countStyle: .file))
                    LabeledContent("Signed IPAs", value: ByteCountFormatter.string(
                        fromByteCount: folderSize(Paths.signed), countStyle: .file))
                }
            }
            .navigationTitle("Cloud")
        }
    }

    private func folderSize(_ url: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        return (files?.allObjects as? [URL] ?? []).reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
