import Compression
import Foundation

enum ImportFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text } else { return nil } }
}

// MARK: - .deb

/// Pulls the iOS app out of a .deb. Tweaks and anything else needing a jailbreak have no app to pull out.
enum DebImporter {
    /// Writes `<destination>/Payload/<Name>.app` and returns the Payload folder.
    static func extractApp(deb: URL, to destination: URL) throws -> URL {
        let file = try FileHandle(forReadingFrom: deb)
        defer { try? file.close() }
        let member = try findDataMember(file)
        let payload = destination.appendingPathComponent("Payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)

        var remaining = member.size
        let read: (Int) -> Data? = { count in
            guard remaining > 0, let data = try? file.read(upToCount: min(count, remaining)), !data.isEmpty else { return nil }
            remaining -= data.count
            return data
        }
        let source: ByteSource
        switch member.kind {
        case "tar": source = ByteSource(read)
        case "gz":
            try skipGzipHeader(read)
            source = ByteSource(try InputFilter<Data>(.decompress, using: .zlib, readingFrom: read))
        case "xz": source = ByteSource(try InputFilter<Data>(.decompress, using: .lzma, readingFrom: read))
        default:
            throw ImportFailure.message("This .deb is compressed with \(member.kind), which DockBox can't open yet. Only gzip and xz are supported.")
        }
        guard try unpackTar(source, into: payload) else {
            throw ImportFailure.message("This .deb has no app inside. It's probably a jailbreak tweak, which can't run without a jailbreak.")
        }
        return payload
    }

    private static func findDataMember(_ file: FileHandle) throws -> (size: Int, kind: String) {
        guard try file.read(upToCount: 8) == Data("!<arch>\n".utf8) else {
            throw ImportFailure.message("This file isn't a valid .deb.")
        }
        while let header = try file.read(upToCount: 60), header.count == 60 {
            let name = String(decoding: header[0..<16], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " /"))
            guard let size = Int(String(decoding: header[48..<58], as: UTF8.self).trimmingCharacters(in: .whitespaces)) else { break }
            if name.hasPrefix("data.tar") {
                let suffix = String(name.dropFirst("data.tar".count).drop { $0 == "." })
                return (size, suffix.isEmpty ? "tar" : suffix)
            }
            try file.seek(toOffset: try file.offset() + UInt64(size + size % 2))
        }
        throw ImportFailure.message("This .deb has no contents.")
    }

    private static func skipGzipHeader(_ read: (Int) -> Data?) throws {
        func take(_ n: Int) throws -> [UInt8] {
            var out = [UInt8]()
            while out.count < n {
                guard let d = read(n - out.count) else { throw ImportFailure.message("This .deb is damaged.") }
                out += d
            }
            return out
        }
        let head = try take(10)
        guard head[0] == 0x1f, head[1] == 0x8b, head[2] == 8 else { throw ImportFailure.message("This .deb is damaged.") }
        let flags = head[3]
        if flags & 4 != 0 { let x = try take(2); _ = try take(Int(x[0]) + Int(x[1]) << 8) }
        if flags & 8 != 0 { while try take(1)[0] != 0 {} }
        if flags & 16 != 0 { while try take(1)[0] != 0 {} }
        if flags & 2 != 0 { _ = try take(2) }
    }

    /// Reads exact byte counts from a raw or decompressing stream.
    private final class ByteSource {
        private let next: (Int) throws -> Data?
        private var buffer = Data()
        init(_ read: @escaping (Int) -> Data?) { next = read }
        init(_ filter: InputFilter<Data>) { next = { try filter.readData(ofLength: $0) } }

        /// Up to `count` bytes; fewer only at the end of the stream.
        func read(_ count: Int) throws -> Data {
            while buffer.count < count, let more = try next(max(65536, count - buffer.count)), !more.isEmpty { buffer.append(more) }
            let out = Data(buffer.prefix(count))
            buffer = Data(buffer.dropFirst(out.count))
            return out
        }
    }

    /// Returns whether an app was found. Only the first app is kept.
    private static func unpackTar(_ source: ByteSource, into payload: URL) throws -> Bool {
        let fm = FileManager.default
        var appRoot: String?
        var longName: String?
        func text(_ d: Data) -> String { String(decoding: d.prefix { $0 != 0 }, as: UTF8.self) }
        func octal(_ d: Data) -> Int { Int(text(d).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0 }

        while true {
            let header = try source.read(512)
            guard header.count == 512, header.contains(where: { $0 != 0 }) else { break }
            let h = Data(header)
            var name = text(h[0..<100])
            if h[257..<262] == Data("ustar".utf8) {
                let prefix = text(h[345..<500])
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            let size = octal(h[124..<136]), mode = octal(h[100..<108]), type = h[156]
            let link = text(h[157..<257])
            let padded = (size + 511) / 512 * 512

            if type == UInt8(ascii: "x") || type == UInt8(ascii: "L") || type == UInt8(ascii: "g") {
                let body = try source.read(padded).prefix(size)
                if type == UInt8(ascii: "L") { longName = text(Data(body)) }
                if type == UInt8(ascii: "x"), let path = paxPath(Data(body)) { longName = path }
                continue
            }
            if let override = longName { name = override; longName = nil }
            let parts = name.split(separator: "/").map(String.init).filter { $0 != "." }

            var relative: [String]?
            if !parts.contains("..") {
                if let i = parts.firstIndex(where: { $0.hasSuffix(".app") }), i > 0, parts[i - 1] == "Applications",
                   appRoot == nil || appRoot == parts[i] {
                    appRoot = parts[i]
                    relative = Array(parts[i...])
                }
            }
            guard let relative else {
                var left = padded
                while left > 0 { let got = try source.read(min(left, 1 << 20)).count; if got == 0 { break }; left -= got }
                continue
            }
            let target = relative.reduce(payload) { $0.appendingPathComponent($1) }
            switch type {
            case UInt8(ascii: "5"):
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case UInt8(ascii: "2"):
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Links leading outside the app would point at nothing once it's in a container.
                if !link.hasPrefix("/"), staysInside(link, depth: relative.count - 1) {
                    try? fm.removeItem(at: target)
                    try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
                }
            case 0, UInt8(ascii: "0"):
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: mode == 0 ? 0o644 : mode])
                let out = try FileHandle(forWritingTo: target)
                var left = size
                while left > 0 {
                    let chunk = try source.read(min(left, 1 << 20))
                    if chunk.isEmpty { throw ImportFailure.message("This .deb is damaged or cut off.") }
                    try out.write(contentsOf: chunk)
                    left -= chunk.count
                }
                try out.close()
                if padded > size { _ = try source.read(padded - size) }
            default:
                if padded > 0 { _ = try source.read(padded) }
            }
        }
        return appRoot != nil
    }

    private static func staysInside(_ link: String, depth: Int) -> Bool {
        var level = depth
        for part in link.split(separator: "/") {
            if part == ".." { level -= 1 } else if part != "." { level += 1 }
            if level < 1 { return false }
        }
        return true
    }

    private static func paxPath(_ body: Data) -> String? {
        for line in String(decoding: body, as: UTF8.self).split(separator: "\n") {
            if let range = line.range(of: " path=") { return String(line[range.upperBound...]) }
        }
        return nil
    }
}

// MARK: - Ren'Py

enum RenPyLocator {
    /// Finds a Ren'Py game's `game` folder in an unpacked PC or Mac download, or nil if this isn't one.
    static func gameFolder(in root: URL) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        var best: URL?
        for case let url as URL in walker where url.lastPathComponent == "game" {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let names = try? fm.contentsOfDirectory(atPath: url.path),
                  names.contains(where: { $0.hasSuffix(".rpa") || $0.hasSuffix(".rpyc") || $0.hasSuffix(".rpy") }) else { continue }
            if best == nil || url.pathComponents.count < best!.pathComponents.count { best = url }
        }
        return best
    }
}

// MARK: - itch.io

/// Downloads free games the way the itch.io site does. Paid games need the buyer's account, so they stop with a message.
final class ItchClient {
    struct Upload: Equatable { var id: Int; var name: String; var size: String }

    static func handles(_ url: URL) -> Bool {
        (url.host?.lowercased().hasSuffix(".itch.io") ?? false) && url.pathComponents.count >= 2
    }

    private let session: URLSession
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    init() { session = URLSession(configuration: .ephemeral) }

    private func request(_ url: URL, referer: URL? = nil, csrf: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer { req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        if let csrf {
            req.httpMethod = "POST"
            req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let safe = csrf.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? csrf
            req.httpBody = Data("csrf_token=\(safe)".utf8)
        }
        return req
    }

    private func html(_ req: URLRequest) async throws -> String {
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImportFailure.message("itch.io returned error \(http.statusCode). Check the link.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func frontPage(_ page: URL) async -> String {
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000) }
            guard let (data, response) = try? await session.data(for: request(page)) else { continue }
            if (response as? HTTPURLResponse)?.statusCode == 200 { return String(decoding: data, as: UTF8.self) }
        }
        return ""
    }

    private func csrf(_ page: URL) throws -> String {
        guard let token = session.configuration.httpCookieStorage?.cookies(for: page)?.first(where: { $0.name == "itchio_token" })?.value else {
            throw ImportFailure.message("itch.io didn't start a download session. Try again.")
        }
        return token
    }

    private func json(_ data: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:] }

    func uploads(page: URL) async throws -> [Upload] {
        // A busy game page can answer 429 and still set the session cookie, so only a missing cookie stops the import.
        let front = await frontPage(page)
        if let price = front.range(of: #""min_price":\s*(\d+)"#, options: .regularExpression).map({ String(front[$0]) }),
           let cents = Int(price.filter(\.isNumber)), cents > 0 {
            throw ImportFailure.message("This is a paid game, and DockBox can only download free ones from itch.io. Buy it on itch.io, then import the file.")
        }
        let token = try csrf(page)
        let (data, _) = try await session.data(for: request(page.appendingPathComponent("download_url"), referer: page, csrf: token))
        guard let link = (json(data)["url"] as? String).flatMap(URL.init(string:)) else {
            throw ImportFailure.message("itch.io wouldn't give a download for this game. It may need an account or may not be downloadable.")
        }
        let list = Self.parseUploads(try await html(request(link, referer: page)))
        guard !list.isEmpty else { throw ImportFailure.message("This game has no files to download.") }
        return list
    }

    func downloadURL(upload: Upload, page: URL) async throws -> URL {
        var parts = URLComponents(url: page.appendingPathComponent("file/\(upload.id)"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "source", value: "game_download")]
        let (data, _) = try await session.data(for: request(parts.url!, referer: page, csrf: try csrf(page)))
        guard let url = (json(data)["url"] as? String).flatMap(URL.init(string:)) else {
            throw ImportFailure.message("itch.io wouldn't give a download link for \(upload.name).")
        }
        return url
    }

    static func parseUploads(_ html: String) -> [Upload] {
        html.components(separatedBy: #"<div class="upload""#).dropFirst().compactMap { block in
            guard let id = capture(#"data-upload_id="(\d+)""#, block).flatMap(Int.init),
                  let name = capture(#"class="name"[^>]*title="([^"]+)""#, block) ?? capture(#"title="([^"]+)"[^>]*class="name""#, block) else { return nil }
            return Upload(id: id, name: name, size: capture(#"file_size"><span>([^<]+)"#, block) ?? "")
        }
    }

    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// The file most likely to run here: iOS builds first, then what a Ren'Py game can be converted from.
    static func best(_ uploads: [Upload]) -> Upload? {
        func rank(_ name: String) -> Int? {
            let n = name.lowercased()
            if n.hasSuffix(".ipa") { return 0 }
            if n.hasSuffix(".deb") { return 1 }
            guard n.hasSuffix(".zip") else { return nil }
            if n.contains("-pc") { return 2 }
            if n.contains("-win") { return 3 }
            if n.contains("-mac") { return 4 }
            return 5
        }
        return uploads.filter { rank($0.name) != nil }.min { rank($0.name)! < rank($1.name)! }
    }
}
