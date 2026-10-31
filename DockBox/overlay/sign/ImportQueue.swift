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
        Task {
            for (row, url) in new {
                await process(row.id) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try await self.add(url, named: url.lastPathComponent, sourceURL: nil, store: store)
                }
            }
        }
    }

    func enqueue(urls: [URL], store: AppStore) {
        let new = urls.map { (Row(label: $0.absoluteString), $0) }
        rows.append(contentsOf: new.map(\.0))
        Task {
            for (row, url) in new {
                await process(row.id) {
                    self.set(row.id, .downloading)
                    var from = url
                    var name = url.lastPathComponent
                    if ItchClient.handles(url) {
                        let itch = ItchClient()
                        let uploads = try await itch.uploads(page: url)
                        guard let upload = ItchClient.best(uploads) else {
                            let files = uploads.map(\.name).joined(separator: ", ")
                            throw ImportFailure.message("No file here can run on iPhone. Available: \(files)")
                        }
                        from = try await itch.downloadURL(upload: upload, page: url)
                        name = upload.name
                    }
                    let (tmp, response) = try await URLSession.shared.download(from: from)
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Server returned \(http.statusCode)"])
                    }
                    if !ItchClient.handles(url), let suggested = response.suggestedFilename { name = suggested }
                    self.set(row.id, .importing)
                    // Only a direct IPA link can be fetched again as-is on restore.
                    let direct = !ItchClient.handles(url) && name.lowercased().hasSuffix(".ipa")
                    try await self.add(tmp, named: name, sourceURL: direct ? url.absoluteString : nil, store: store)
                }
            }
        }
    }

    /// Adds a downloaded or picked file by what it is: an IPA as-is, a .deb or Ren'Py zip converted to an IPA first.
    private func add(_ file: URL, named name: String, sourceURL: String?, store: AppStore) async throws {
        let lower = name.lowercased()
        if lower.hasSuffix(".deb") {
            let work = Paths.work()
            defer { try? FileManager.default.removeItem(at: work) }
            let payload = try DebImporter.extractApp(deb: file, to: work)
            let ipa = work.appendingPathComponent("converted.ipa")
            try FileManager.default.zipItem(at: payload, to: ipa, shouldKeepParent: true, compressionMethod: .deflate)
            try await store.addIPA(copying: ipa, sourceURL: nil)
        } else if lower.hasSuffix(".zip") {
            guard let ipa = try await RenPyPackager.package(zip: file, title: RenPyPackager.title(fromFileName: name)) else {
                throw ImportFailure.message("This zip isn't a Ren'Py game, so it can't run on iPhone.")
            }
            defer { try? FileManager.default.removeItem(at: ipa) }
            try await store.addIPA(copying: ipa, sourceURL: nil)
        } else if lower.hasSuffix(".apk") {
            throw ImportFailure.message("APK files are Android apps, and iPhone can't run them.")
        } else {
            try await store.addIPA(copying: file, sourceURL: sourceURL)
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
