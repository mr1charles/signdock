import Foundation
import CryptoKit
import CommonCrypto
import Security

enum CloudConfig {
    static let url = URL(string: "https://rxuuqplvjxrrldacrpdy.supabase.co")!
    /// Publishable key: meant to ship inside clients. Data is protected by row-level security.
    static let key = "sb_publishable_GqmvcpcjBimCZ8YAAK19cg_oadYsZN1"
    static let bucket = "vault"
}

struct CloudError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct CloudSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userId: UUID
    var email: String
}

enum VaultState { case unknown, needsSetup, locked, ready }

/// Client-side encryption: the server only ever sees ciphertext for certificates.
enum VaultCrypto {
    static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pass = Array(passphrase.utf8)
        _ = salt.withUnsafeBytes { saltPtr in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.map { Int8(bitPattern: $0) }, pass.count,
                                 saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000, &out, out.count)
        }
        return SymmetricKey(data: Data(out))
    }
    static func seal(_ data: Data, _ key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw CloudError("Encryption failed") }
        return combined
    }
    static func open(_ data: Data, _ key: SymmetricKey) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: key)
    }
    static let verifierPlain = Data("signdock-vault-ok".utf8)
}

private enum KC {
    static let service = "dev.signdock.cloud"
    static func set(_ data: Data, _ account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    static func remove(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

enum CloudDates {
    private static let plain: ISO8601DateFormatter = ISO8601DateFormatter()
    static func string(_ d: Date) -> String { plain.string(from: d) }
    /// PostgREST returns microseconds ("...09.892431+00:00"); drop the fraction and parse.
    static func parse(_ s: String) -> Date? {
        let cleaned = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return plain.date(from: cleaned)
    }
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom { d, enc in var c = enc.singleValueContainer(); try c.encode(string(d)) }
        return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = parse(s) else { throw CloudError("Bad date: \(s)") }
            return date
        }
        return d
    }
}

@MainActor
final class Cloud: ObservableObject {
    @Published private(set) var session: CloudSession?
    @Published private(set) var vault: VaultState = .unknown
    @Published var status = ""
    @Published var busy = false
    var vaultKey: SymmetricKey?
    var signedIn: Bool { session != nil }

    init() {
        if let data = KC.get("session"), let s = try? CloudDates.decoder.decode(CloudSession.self, from: data) {
            session = s
        }
        if let raw = KC.get("vaultKey") { vaultKey = SymmetricKey(data: raw) }
    }

    // MARK: Email code sign-in

    func sendCode(to email: String) async throws {
        _ = try await api("POST", "auth/v1/otp", body: json(["email": email, "create_user": true]), auth: false)
    }

    func verify(email: String, code: String) async throws {
        let data = try await api("POST", "auth/v1/verify",
                                 body: json(["type": "email", "email": email, "token": code]), auth: false)
        try adopt(data, fallbackEmail: email)
        await loadVault()
    }

    func signOut() {
        session = nil; vault = .unknown; vaultKey = nil
        KC.remove("session"); KC.remove("vaultKey")
    }

    private struct AuthResponse: Decodable {
        var accessToken: String, refreshToken: String, expiresIn: Int
        var user: User
        struct User: Decodable { var id: UUID; var email: String? }
    }

    private func adopt(_ data: Data, fallbackEmail: String) throws {
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        let r = try dec.decode(AuthResponse.self, from: data)
        let s = CloudSession(accessToken: r.accessToken, refreshToken: r.refreshToken,
                             expiresAt: Date().addingTimeInterval(TimeInterval(r.expiresIn)),
                             userId: r.user.id, email: r.user.email ?? fallbackEmail)
        session = s
        if let enc = try? CloudDates.encoder.encode(s) { KC.set(enc, "session") }
    }

    private func ensureFreshToken() async throws {
        guard let s = session else { throw CloudError("Not signed in.") }
        guard s.expiresAt.timeIntervalSinceNow < 60 else { return }
        let data = try await api("POST", "auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                 body: json(["refresh_token": s.refreshToken]), auth: false)
        try adopt(data, fallbackEmail: s.email)
    }

    // MARK: Vault

    private struct VaultRow: Codable { var kdfSalt: String; var verifier: String }

    func loadVault() async {
        do {
            let data = try await api("GET", "rest/v1/vault_profiles", query: [URLQueryItem(name: "select", value: "*")])
            let rows = try CloudDates.decoder.decode([VaultRow].self, from: data)
            guard let row = rows.first else { vault = .needsSetup; return }
            if let key = vaultKey, let v = Data(base64Encoded: row.verifier),
               (try? VaultCrypto.open(v, key)) == VaultCrypto.verifierPlain {
                vault = .ready
            } else { vaultKey = nil; KC.remove("vaultKey"); vault = .locked }
        } catch { status = error.localizedDescription }
    }

    func setUpVault(passphrase: String) async throws {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = VaultCrypto.deriveKey(passphrase: passphrase, salt: salt)
        let verifier = try VaultCrypto.seal(VaultCrypto.verifierPlain, key)
        let row = VaultRow(kdfSalt: salt.base64EncodedString(), verifier: verifier.base64EncodedString())
        _ = try await api("POST", "rest/v1/vault_profiles", body: CloudDates.encoder.encode(row),
                          extra: ["Prefer": "return=minimal"])
        remember(key)
    }

    func unlock(passphrase: String) async throws {
        let data = try await api("GET", "rest/v1/vault_profiles", query: [URLQueryItem(name: "select", value: "*")])
        guard let row = try CloudDates.decoder.decode([VaultRow].self, from: data).first,
              let salt = Data(base64Encoded: row.kdfSalt), let verifier = Data(base64Encoded: row.verifier)
        else { throw CloudError("No vault found for this account.") }
        let key = VaultCrypto.deriveKey(passphrase: passphrase, salt: salt)
        guard (try? VaultCrypto.open(verifier, key)) == VaultCrypto.verifierPlain else {
            throw CloudError("Wrong passphrase.")
        }
        remember(key)
    }

    private func remember(_ key: SymmetricKey) {
        vaultKey = key
        KC.set(key.withUnsafeBytes { Data($0) }, "vaultKey")
        vault = .ready
    }

    // MARK: HTTP

    func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    @discardableResult
    func api(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
             contentType: String = "application/json", extra: [String: String] = [:], auth: Bool = true) async throws -> Data {
        var req = try await request(method, path, query: query, contentType: contentType, extra: extra, auth: auth)
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.check(data, response)
        return data
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], contentType: String? = nil,
                 extra: [String: String] = [:], auth: Bool = true) async throws -> URLRequest {
        if auth { try await ensureFreshToken() }
        var comps = URLComponents(url: CloudConfig.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue(CloudConfig.key, forHTTPHeaderField: "apikey")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if auth, let token = session?.accessToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in extra { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    static func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw CloudError("No response.") }
        guard (200..<300).contains(http.statusCode) else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = (obj?["msg"] ?? obj?["message"] ?? obj?["error_description"] ?? obj?["error"]) as? String
            throw CloudError(msg ?? "Server error \(http.statusCode)")
        }
    }
}
