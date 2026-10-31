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
    @State private var showingMemory = false
    @State private var showingPairing = false
    @State private var paired = DockBoxJIT.hasPairingFile
    @Namespace private var tabs

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { showingMemory = true } label: {
                    DBStatusChip(icon: "memorychip", text: memoryText, tone: memoryTone)
                }
                Button { showingPairing = true } label: {
                    DBStatusChip(icon: "bolt.fill", text: paired ? "JIT ready" : "Pair for JIT", tone: paired ? .good : .warn)
                }
                Button { section = .cloud } label: {
                    DBStatusChip(icon: cloud.signedIn ? "checkmark.icloud" : "icloud.slash",
                                 text: cloud.signedIn ? "Synced" : "Sign in", tone: cloud.signedIn ? .good : .neutral)
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.top, 8)

            HStack(spacing: 4) {
                ForEach(HubSection.allCases) { item in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { section = item }
                    } label: {
                        Text(item.rawValue)
                            .font(.subheadline.weight(section == item ? .semibold : .regular))
                            .foregroundStyle(section == item ? .white : .secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background {
                                if section == item {
                                    Capsule().fill(DBTheme.gradient).matchedGeometryEffect(id: "tab", in: tabs)
                                }
                            }
                    }.buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Capsule().fill(Color(.secondarySystemBackground)))
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
        .sheet(isPresented: $showingMemory) { DockBoxMemoryView() }
        .sheet(isPresented: $showingPairing) { DockBoxPairingView { paired = true } }
        .onAppear {
            DockBoxMemory.startWatching()
            DockBoxMemory.sweepStaleWork()
        }
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
private extension SignDockHub {
    var memoryText: String {
        switch DockBoxMemory.grant {
        case .active: return "More RAM on"
        case .notGranted: return "Normal RAM"
        case .unknown: return "RAM"
        }
    }
    var memoryTone: DBStatusChip.Tone {
        switch DockBoxMemory.grant {
        case .active: return .good
        case .notGranted: return .warn
        case .unknown: return .neutral
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
