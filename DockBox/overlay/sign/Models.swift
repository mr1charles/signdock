import Foundation

enum Paths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("SignDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static var library: URL { dir(root.appendingPathComponent("Library", isDirectory: true)) }
    static var certs: URL { dir(root.appendingPathComponent("Certs", isDirectory: true)) }
    /// Visible in the Files app (UIFileSharingEnabled).
    static var signed: URL {
        dir(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Signed", isDirectory: true))
    }
    static func work() -> URL {
        dir(FileManager.default.temporaryDirectory.appendingPathComponent("sign-\(UUID().uuidString)", isDirectory: true))
    }
    private static func dir(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct CertificateProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// Which Apple ID / free developer account this certificate belongs to (for switching).
    var account: String?
    var teamID: String
    var profileName: String
    var expires: Date?
    var addedAt = Date()
    var revoked = false
    /// Whether the provisioning profile grants the Increased Memory Limit entitlement.
    var grantsMoreMemory: Bool?

    var folder: URL { Paths.certs.appendingPathComponent(id.uuidString, isDirectory: true) }
    var p12URL: URL { folder.appendingPathComponent("cert.p12") }
    var profileURL: URL { folder.appendingPathComponent("profile.mobileprovision") }
    var isExpired: Bool { (expires ?? .distantFuture) < Date() }
}

struct LibraryItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var bundleID: String
    var version: String
    var size: Int64
    var addedAt = Date()
    /// Where it was downloaded from, if imported by URL (lets a restore re-download it).
    var sourceURL: String?

    var fileURL: URL { Paths.library.appendingPathComponent("\(id.uuidString).ipa") }
    /// LiveContainer-family apps can't run inside the container (a nested container crashes on launch).
    var looksLikeContainer: Bool {
        let id = bundleID.lowercased()
        return id.contains("livecontainer") || id.contains("dockbox")
    }
    /// False after a cloud restore until the file has been downloaded again.
    var hasLocalFile: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
}

struct SignRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var date = Date()
    var appName: String
    var bundleID: String
    var version: String
    var certName: String
    var success: Bool
    var message: String
    var outputName: String?
    var duration: Double
    var libraryID: UUID?

    var outputURL: URL? {
        guard let outputName else { return nil }
        let url = Paths.signed.appendingPathComponent(outputName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
