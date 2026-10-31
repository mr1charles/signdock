import Foundation

@main
enum ImporterTests {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ label: String) {
        print((ok ? "ok   " : "FAIL ") + label)
        if !ok { failures += 1 }
    }

    static func main() async {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        for name in ["rootless-xz.deb", "rootful-gz.deb", "plain.deb"] {
            let out = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                let payload = try DebImporter.extractApp(deb: root.appendingPathComponent(name), to: out)
                let app = payload.appendingPathComponent("Demo.app")
                check(fm.contents(atPath: app.appendingPathComponent("Info.plist").path) == Data("plist".utf8), "\(name): file contents")
                let exe = app.appendingPathComponent("Demo")
                check(fm.contents(atPath: exe.path)?.count == 80000, "\(name): 80 KB executable intact")
                check(fm.isExecutableFile(atPath: exe.path), "\(name): executable bit kept")
                check(fm.contents(atPath: app.appendingPathComponent(String(repeating: "deep/", count: 30) + "asset.bin").path) == Data("long".utf8), "\(name): long path")
                check((try? fm.destinationOfSymbolicLink(atPath: app.appendingPathComponent("inside").path)) == "Info.plist", "\(name): inner link kept")
                check((try? fm.destinationOfSymbolicLink(atPath: app.appendingPathComponent("outside").path)) == nil, "\(name): escaping link dropped")
                check(!fm.fileExists(atPath: out.appendingPathComponent("escape").path) && !fm.fileExists(atPath: payload.appendingPathComponent("escape").path), "\(name): traversal blocked")
                check(!fm.fileExists(atPath: payload.appendingPathComponent("Library").path), "\(name): files outside the app skipped")
            } catch { check(false, "\(name): threw \(error.localizedDescription)") }
        }
        for (name, expected) in [("tweak.deb", "no app"), ("zstd.deb", "zst")] {
            do { _ = try DebImporter.extractApp(deb: root.appendingPathComponent(name), to: fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)); check(false, "\(name): should fail") }
            catch { check(error.localizedDescription.contains(expected), "\(name): says \(error.localizedDescription)") }
        }
        let game = RenPyLocator.gameFolder(in: root.appendingPathComponent("renpy"))
        check(game?.path.hasSuffix("MyGame-1.0-pc/game") == true, "Ren'Py game folder found, shallowest wins")
        check(RenPyLocator.gameFolder(in: root.appendingPathComponent("notrenpy")) == nil, "non-Ren'Py zip rejected")

        let picks: [ItchClient.Upload] = ["a-win.zip", "a-pc.zip", "a.apk"].enumerated().map { .init(id: $0, name: $1, size: "") }
        check(ItchClient.best(picks)?.name == "a-pc.zip", "itch: PC zip preferred")
        check(ItchClient.best([.init(id: 1, name: "a.apk", size: "")]) == nil, "itch: APK-only game has no pick")

        // Live: the site can change without this code changing, and that should be seen on every build.
        do {
            let page = URL(string: "https://3005jin.itch.io/7-minutes-in-the-closet")!
            let itch = ItchClient()
            let uploads = try await itch.uploads(page: page)
            check(!uploads.isEmpty, "itch live: \(uploads.count) files listed: \(uploads.map(\.name))")
            let upload = ItchClient.best(uploads)!
            var req = URLRequest(url: try await itch.downloadURL(upload: upload, page: page))
            req.setValue("bytes=0-3", forHTTPHeaderField: "Range")
            let (data, _) = try await URLSession.shared.data(for: req)
            check(data.starts(with: Data("PK".utf8)), "itch live: \(upload.name) downloads as a zip")
        } catch { check(false, "itch live: \(error.localizedDescription)") }

        print(failures == 0 ? "All passed." : "\(failures) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
