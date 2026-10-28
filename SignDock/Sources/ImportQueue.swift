import Foundation

/// Imports any number of IPA files or URLs. One failure never stops the rest.
@MainActor
final class ImportQueue: ObservableObject {
    struct Row: Identifiable {
        enum State: Equatable { case waiting, downloading, importing, done, failed(String) }
        let id = UUID()
        var label: String
        var state: State = .waiting
    }

    @Published var rows: [Row] = []
    private var busy = false

    var active: Bool { rows.contains { $0.state == .waiting || $0.state == .downloading || $0.state == .importing } }

    func clearFinished() { rows.removeAll { $0.state == .done } }

    func enqueue(files: [URL], store: AppStore) {
        let new = files.map { (Row(label: $0.lastPathComponent), $0) }
        rows.append(contentsOf: new.map(\.0))
        Task { for (row, url) in new { await process(row.id) { try await store.addIPA(copying: url) } }; }
    }

    func enqueue(urls: [URL], store: AppStore) {
        let new = urls.map { (Row(label: $0.absoluteString), $0) }
        rows.append(contentsOf: new.map(\.0))
        Task {
            for (row, url) in new {
                await process(row.id) {
                    self.set(row.id, .downloading)
                    let (tmp, response) = try await URLSession.shared.download(from: url)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Server returned \(http.statusCode)"])
                    }
                    self.set(row.id, .importing)
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    try await store.addIPA(copying: tmp, sourceURL: url.absoluteString)
                }
            }
        }
    }

    /// Parses pasted text: one link per line (or whitespace separated), ignoring anything that isn't http(s).
    static func urls(from text: String) -> [URL] {
        text.split(whereSeparator: { $0.isWhitespace })
            .compactMap { URL(string: String($0)) }
            .filter { $0.scheme == "http" || $0.scheme == "https" }
    }

    private func process(_ id: UUID, _ work: @escaping () async throws -> Void) async {
        // Serialise so rows run one at a time in order.
        while busy { try? await Task.sleep(nanoseconds: 100_000_000) }
        busy = true
        defer { busy = false }
        set(id, .importing)
        do { try await work(); set(id, .done) }
        catch { set(id, .failed(error.localizedDescription)) }
    }

    private func set(_ id: UUID, _ state: Row.State) {
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].state = state }
    }
}
