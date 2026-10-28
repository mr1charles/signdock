import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openURL) private var openURL

    private func installed(_ scheme: String) -> Bool {
        UIApplication.shared.canOpenURL(URL(string: "\(scheme)://")!)
    }

    var body: some View {
        NavigationStack {
            Form {
                AccountView()

                Section {
                    row("DockBox", installed("dockbox"))
                    row("StikDebug", installed("stikjit"))
                    if installed("dockbox") {
                        Button("Open DockBox") { openURL(URL(string: "dockbox://")!) }
                    }
                } header: { Text("Companion apps") }
                footer: { Text("Share a signed IPA to DockBox from the History tab to run it inside the container. JIT can come from DockBox's built-in provider or StikDebug.") }

                Section("Storage") {
                    LabeledContent("Library", value: ByteCountFormatter.string(fromByteCount: store.library.reduce(0) { $0 + $1.size }, countStyle: .file))
                    LabeledContent("Signed IPAs", value: ByteCountFormatter.string(fromByteCount: folderSize(Paths.signed), countStyle: .file))
                }

                Section {
                    Text("Signing uses Zsign. SignDock is GPL-3.0; source is available from wherever you got this build.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("About") }
            }
            .navigationTitle("Settings")
        }
    }

    private func row(_ name: String, _ found: Bool) -> some View {
        HStack { Text(name); Spacer(); Text(found ? "Installed" : "Not found").foregroundStyle(found ? .green : .secondary) }
    }

    private func folderSize(_ url: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        return (files?.allObjects as? [URL] ?? []).reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
