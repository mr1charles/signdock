import SwiftUI

@available(iOS 16.0, *)
struct LibraryView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var importer: ImportQueue
    @EnvironmentObject var sharedModel: SharedModel
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var search = ""
    @State private var pickingFiles = false
    @State private var addingURLs = false
    @State private var signing: [LibraryItem]?

    private var items: [LibraryItem] {
        search.isEmpty ? store.library
            : store.library.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                if !importer.rows.isEmpty {
                    Section("Importing") {
                        ForEach(importer.rows) { row in ImportRow(row: row) }
                        if !importer.active {
                            Button("Clear finished") { importer.clearFinished() }
                        }
                    }
                }
                Section(items.isEmpty ? "" : "\(items.count) apps") {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(item.name).font(.headline)
                                if !item.hasLocalFile {
                                    Image(systemName: "icloud.and.arrow.down").foregroundStyle(.orange)
                                }
                            }
                            Text("\(item.bundleID) · v\(item.version) · \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .swipeActions {
                            Button(role: .destructive) { store.remove(item) } label: { Label("Delete", systemImage: "trash") }
                            Button { signing = [item] } label: { Label("Sign", systemImage: "signature") }.tint(.blue)
                            if item.hasLocalFile {
                                Button {
                                    // LiveContainer installs a file URL handed to it as a deep link.
                                    sharedModel.selectedTab = .apps
                                    sharedModel.deepLink = item.fileURL
                                } label: { Label("Container", systemImage: "square.and.arrow.down.on.square") }.tint(.green)
                            }
                        }
                    }
                }
            }
            .overlay {
                if store.library.isEmpty && importer.rows.isEmpty {
                    ContentUnavailableLike(title: "No apps yet", message: "Import IPA files or paste download links with +.")
                }
            }
            .searchable(text: $search)
            .navigationTitle("Library")
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editMode.isEditing ? "Done" : "Select") {
                        editMode = editMode.isEditing ? .inactive : .active
                        selection.removeAll()
                    }.disabled(store.library.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if editMode.isEditing {
                        Button(selection.count == items.count ? "None" : "All") {
                            selection = selection.count == items.count ? [] : Set(items.map(\.id))
                        }
                    } else {
                        Menu {
                            Button { pickingFiles = true } label: { Label("IPA files…", systemImage: "doc") }
                            Button { addingURLs = true } label: { Label("From links…", systemImage: "link") }
                        } label: { Image(systemName: "plus") }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if editMode.isEditing {
                        Button("Sign \(selection.count) selected") {
                            signing = store.library.filter { selection.contains($0.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selection.isEmpty)
                    }
                }
            }
            .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.ipa, .data], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { importer.enqueue(files: urls, store: store) }
            }
            .sheet(isPresented: $addingURLs) { URLInputSheet() }
            .sheet(item: Binding(get: { signing.map(SignRequest.init) }, set: { signing = $0?.items })) { request in
                SignSheet(items: request.items)
            }
        }
    }
}

struct SignRequest: Identifiable {
    let id = UUID()
    let items: [LibraryItem]
    init(_ items: [LibraryItem]) { self.items = items }
}

@available(iOS 16.0, *)
struct ImportRow: View {
    let row: ImportQueue.Row
    var body: some View {
        HStack {
            Text(row.label).lineLimit(1).truncationMode(.middle)
            Spacer()
            switch row.state {
            case .waiting: Text("Waiting").foregroundStyle(.secondary)
            case .downloading, .importing: ProgressView()
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message): Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}

@available(iOS 16.0, *)
struct URLInputSheet: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var importer: ImportQueue
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                Text("Paste one link per line. Each is downloaded and added to your library.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary)).padding()
            }
            .navigationTitle("Add from links")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    let urls = ImportQueue.urls(from: text)
                    Button("Add \(urls.count)") { importer.enqueue(urls: urls, store: store); dismiss() }
                        .disabled(urls.isEmpty)
                }
            }
        }
    }
}

/// iOS 16-compatible stand-in for ContentUnavailableView.
@available(iOS 16.0, *)
struct ContentUnavailableLike: View {
    let title: String, message: String
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding()
    }
}
