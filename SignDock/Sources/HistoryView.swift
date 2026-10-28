import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    @State private var filter = Filter.all
    @State private var signing: [LibraryItem]?
    @State private var confirmClear = false

    enum Filter: String, CaseIterable { case all = "All", ok = "Signed", failed = "Failed" }

    private var rows: [SignRecord] {
        store.history.filter { r in
            (filter == .all || (filter == .ok) == r.success)
                && (search.isEmpty || r.appName.localizedCaseInsensitiveContains(search)
                    || r.bundleID.localizedCaseInsensitiveContains(search)
                    || r.certName.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).listRowBackground(Color.clear)

                ForEach(rows) { record in
                    HStack(alignment: .top) {
                        Image(systemName: record.success ? "checkmark.seal.fill" : "xmark.octagon.fill")
                            .foregroundStyle(record.success ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.appName).font(.headline)
                            Text("\(record.bundleID) · v\(record.version)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text("\(record.certName) · \(record.date.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.1fs", record.duration))")
                                .font(.caption2).foregroundStyle(.secondary)
                            if !record.success { Text(record.message).font(.caption).foregroundStyle(.red) }
                        }
                        Spacer()
                        if let url = record.outputURL { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") } }
                    }
                    .contextMenu {
                        if let item = store.library.first(where: { $0.id == record.libraryID }) {
                            Button { signing = [item] } label: { Label("Sign again", systemImage: "arrow.clockwise") }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { delete(record) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .overlay { if store.history.isEmpty { ContentUnavailableLike(title: "No history", message: "Signed apps show up here.") } }
            .searchable(text: $search)
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) { confirmClear = true }.disabled(store.history.isEmpty)
                }
            }
            .confirmationDialog("Delete all history and signed IPA files?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { store.history.forEach(removeFile); store.history.removeAll() }
            }
            .sheet(item: Binding(get: { signing.map(SignRequest.init) }, set: { signing = $0?.items })) { SignSheet(items: $0.items) }
        }
    }

    private func removeFile(_ r: SignRecord) { if let url = r.outputURL { try? FileManager.default.removeItem(at: url) } }
    private func delete(_ r: SignRecord) { removeFile(r); store.history.removeAll { $0.id == r.id } }
}
