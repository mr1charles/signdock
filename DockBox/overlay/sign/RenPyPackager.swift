import Foundation

/// Turns a Ren'Py download into an app: the shared player with this game's files inside.
enum RenPyPackager {
    static let playerURL = URL(string: "https://github.com/mr1charles/signdock/releases/download/renpy-player/RenPyPlayer.ipa")!
    private static var cachedPlayer: URL { Paths.root.appendingPathComponent("RenPyPlayer.ipa") }

    /// nil when the zip isn't a Ren'Py game.
    static func package(zip: URL, title: String) async throws -> URL? {
        let fm = FileManager.default
        let unpacked = Paths.work()
        defer { try? fm.removeItem(at: unpacked) }
        try fm.unzipItem(at: zip, to: unpacked)
        guard let game = RenPyLocator.gameFolder(in: unpacked) else { return nil }

        if !fm.fileExists(atPath: cachedPlayer.path) {
            let (tmp, response) = try await URLSession.shared.download(from: playerURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ImportFailure.message("Couldn't download the Ren'Py player. Check your connection and try again.")
            }
            try fm.moveItem(at: tmp, to: cachedPlayer)
        }

        let work = Paths.work()
        defer { try? fm.removeItem(at: work) }
        try fm.unzipItem(at: cachedPlayer, to: work)
        let payload = work.appendingPathComponent("Payload")
        let app = payload.appendingPathComponent("RenPyPlayer.app")
        let target = app.appendingPathComponent("base/game")
        try? fm.removeItem(at: target)
        try fm.moveItem(at: game, to: target)

        let plistURL = app.appendingPathComponent("Info.plist")
        guard var plist = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            throw ImportFailure.message("The Ren'Py player is damaged. Delete DockBox's copy by reinstalling, then try again.")
        }
        let slug = title.lowercased().filter { $0.isLetter && $0.isASCII || $0.isNumber }
        plist["CFBundleDisplayName"] = title
        plist["CFBundleName"] = title
        plist["CFBundleIdentifier"] = "com.dockbox.renpy.\(slug.isEmpty ? UUID().uuidString.prefix(8).lowercased() : slug)"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: plistURL)

        let out = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ipa")
        try fm.zipItem(at: payload, to: out, shouldKeepParent: true, compressionMethod: .none) // game archives barely compress, and this saves minutes
        return out
    }

    /// "my-game-1.0-pc.zip" → "My Game"
    static func title(fromFileName name: String) -> String {
        var base = (name as NSString).deletingPathExtension
        if let range = base.range(of: #"[-_ ]v?\d[\w.]*(-(pc|win|mac|market|all))?$"#, options: [.regularExpression, .caseInsensitive]) { base.removeSubrange(range) }
        if let range = base.range(of: #"-(pc|win|mac|market|all)$"#, options: [.regularExpression, .caseInsensitive]) { base.removeSubrange(range) }
        let spaced = base.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
        return spaced.isEmpty ? "Ren'Py game" : spaced.capitalized
    }
}
