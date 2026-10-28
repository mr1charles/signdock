import Foundation
import Security
import Zsign

enum Keychain {
    private static let service = "dev.signdock.cert-password"
    static func set(_ value: String, for id: UUID) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: id.uuidString]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ id: UUID) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString,
                                    kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func remove(_ id: UUID) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: id.uuidString] as CFDictionary)
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var library: [LibraryItem] = [] { didSet { save(library, "library.json") } }
    @Published var certs: [CertificateProfile] = [] { didSet { save(certs, "certs.json") } }
    @Published var history: [SignRecord] = [] { didSet { save(history, "history.json") } }
    @Published var selectedCertID: UUID? {
        didSet { UserDefaults.standard.set(selectedCertID?.uuidString, forKey: "selectedCert") }
    }

    init() {
        library = Self.load("library.json")
        certs = Self.load("certs.json")
        history = Self.load("history.json")
        selectedCertID = UserDefaults.standard.string(forKey: "selectedCert").flatMap(UUID.init)
    }

    var selectedCert: CertificateProfile? {
        certs.first { $0.id == selectedCertID } ?? certs.first
    }

    private static func load<T: Decodable>(_ name: String) -> [T] {
        let url = Paths.root.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([T].self, from: data)) ?? []
    }

    private func save<T: Encodable>(_ value: [T], _ name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        try? encoder.encode(value).write(to: Paths.root.appendingPathComponent(name), options: .atomic)
    }

    // MARK: Library

    func addIPA(copying source: URL, sourceURL: String? = nil) async throws {
        let id = UUID()
        let dest = Paths.library.appendingPathComponent("\(id.uuidString).ipa")
        let info: IPAInfo = try await Task.detached {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: source, to: dest)
            do { return try IPAInspector.inspect(dest) }
            catch { try? FileManager.default.removeItem(at: dest); throw error }
        }.value
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        library.insert(LibraryItem(id: id, name: info.name, bundleID: info.bundleID,
                                   version: info.version, size: size ?? 0, sourceURL: sourceURL), at: 0)
    }

    func remove(_ item: LibraryItem) {
        try? FileManager.default.removeItem(at: item.fileURL)
        library.removeAll { $0.id == item.id }
        Tombstones.add(.library, item.id)
    }

    func removeHistory(_ records: [SignRecord]) {
        let ids = Set(records.map(\.id))
        for r in records { if let url = r.outputURL { try? FileManager.default.removeItem(at: url) }; Tombstones.add(.history, r.id) }
        history.removeAll { ids.contains($0.id) }
    }

    // MARK: Certificates

    func addCertificate(name: String, account: String, p12: URL, profile: URL, password: String) async throws {
        var cert = try await Task.detached { () -> CertificateProfile in
            let scopedA = p12.startAccessingSecurityScopedResource()
            let scopedB = profile.startAccessingSecurityScopedResource()
            defer {
                if scopedA { p12.stopAccessingSecurityScopedResource() }
                if scopedB { profile.stopAccessingSecurityScopedResource() }
            }
            let profileData = try Data(contentsOf: profile)
            guard let info = ProvisionParser.parse(profileData) else { throw StoreError.badProfile }
            let cert = CertificateProfile(name: name.isEmpty ? info.name : name,
                                          account: account.isEmpty ? nil : account, teamID: info.teamID,
                                          profileName: info.name, expires: info.expires)
            try FileManager.default.createDirectory(at: cert.folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: p12, to: cert.p12URL)
            try profileData.write(to: cert.profileURL)
            return cert
        }.value
        Keychain.set(password, for: cert.id)
        cert.revoked = await Self.isRevoked(cert, password: password)
        certs.append(cert)
        if selectedCertID == nil { selectedCertID = cert.id }
    }

    func refreshStatus(_ cert: CertificateProfile) async {
        let revoked = await Self.isRevoked(cert, password: Keychain.get(cert.id))
        if let i = certs.firstIndex(where: { $0.id == cert.id }) { certs[i].revoked = revoked }
    }

    func remove(_ cert: CertificateProfile) {
        try? FileManager.default.removeItem(at: cert.folder)
        Keychain.remove(cert.id)
        certs.removeAll { $0.id == cert.id }
        Tombstones.add(.certs, cert.id)
    }

    /// Zsign's OCSP check: status 1 means revoked; 2 means it couldn't tell (offline, bad password...).
    private static func isRevoked(_ cert: CertificateProfile, password: String) async -> Bool {
        await withCheckedContinuation { cont in
            Zsign.checkRevokage(provisionPath: cert.profileURL.path, p12Path: cert.p12URL.path,
                                p12Password: password) { status, _, _ in
                cont.resume(returning: status == 1)
            }
        }
    }
}

enum StoreError: LocalizedError {
    case badProfile
    var errorDescription: String? { "That isn't a readable .mobileprovision file." }
}
