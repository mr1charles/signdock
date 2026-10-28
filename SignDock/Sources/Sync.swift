import Foundation
import CryptoKit

/// Remembers deletions made while offline/signed-out so a sync can delete them remotely.
/// (Deleting "whatever the server has that I don't" would wipe the cloud on a fresh install.)
enum Tombstones {
    enum Table: String { case library = "library_items", certs = "certificates", history = "sign_history" }
    static func add(_ table: Table, _ id: UUID) {
        var ids = list(table); ids.insert(id.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: "tomb.\(table.rawValue)")
    }
    static func list(_ table: Table) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "tomb.\(table.rawValue)") ?? [])
    }
    static func clear(_ table: Table, _ ids: Set<String>) {
        UserDefaults.standard.set(Array(list(table).subtracting(ids)), forKey: "tomb.\(table.rawValue)")
    }
}

private func marked(_ key: String) -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
private func mark(_ key: String, _ id: UUID) {
    var s = marked(key); s.insert(id.uuidString)
    UserDefaults.standard.set(Array(s), forKey: key)
}

private struct LibraryRow: Codable {
    var id: UUID; var name: String; var bundleId: String; var version: String
    var size: Int64; var sourceUrl: String?; var hasFile: Bool; var addedAt: Date
}
private struct HistoryRow: Codable {
    var id: UUID; var date: Date; var appName: String; var bundleId: String; var version: String
    var certName: String; var success: Bool; var message: String; var duration: Double; var libraryId: UUID?
}
private struct CertRow: Codable {
    var id: UUID; var name: String; var account: String?; var teamId: String
    var profileName: String; var expires: Date?; var revoked: Bool; var addedAt: Date
}
private struct CertBundle: Codable { var p12: Data; var profile: Data; var password: String }

extension Cloud {
    static let maxUploadBytes: Int64 = 50 * 1024 * 1024 // Supabase free-plan object limit

    func syncNow(store: AppStore, backupIPAs: Bool) async {
        guard let session, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if vault == .unknown { await loadVault() }
            status = "Restoring from cloud…"
            try await pull(store: store, uid: session.userId)
            status = "Uploading changes…"
            try await push(store: store, uid: session.userId, backupIPAs: backupIPAs)
            status = "Synced \(Date().formatted(date: .omitted, time: .shortened))"
        } catch { status = "Sync failed: \(error.localizedDescription)" }
    }

    // MARK: Pull (cloud → device)

    private func rows<T: Decodable>(_ table: String, as: T.Type) async throws -> [T] {
        let data = try await api("GET", "rest/v1/\(table)", query: [URLQueryItem(name: "select", value: "*")])
        return try CloudDates.decoder.decode([T].self, from: data)
    }

    private func pull(store: AppStore, uid: UUID) async throws {
        let tombLib = Tombstones.list(.library), tombCert = Tombstones.list(.certs), tombHist = Tombstones.list(.history)

        for row in try await rows("library_items", as: LibraryRow.self)
        where !store.library.contains(where: { $0.id == row.id }) && !tombLib.contains(row.id.uuidString) {
            var item = LibraryItem(id: row.id, name: row.name, bundleID: row.bundleId, version: row.version,
                                   size: row.size, addedAt: row.addedAt, sourceURL: row.sourceUrl)
            item.addedAt = row.addedAt
            store.library.append(item)
            status = "Restoring \(row.name)…"
            await restoreFile(item, hasFile: row.hasFile, uid: uid)
        }
        // Items whose file is still missing (earlier restore interrupted): retry.
        for item in store.library where !item.hasLocalFile {
            await restoreFile(item, hasFile: false, uid: uid)
        }

        for row in try await rows("sign_history", as: HistoryRow.self)
        where !store.history.contains(where: { $0.id == row.id }) && !tombHist.contains(row.id.uuidString) {
            store.history.append(SignRecord(id: row.id, date: row.date, appName: row.appName, bundleID: row.bundleId,
                                            version: row.version, certName: row.certName, success: row.success,
                                            message: row.message, outputName: nil, duration: row.duration,
                                            libraryID: row.libraryId))
            mark("cloud.historyPushed", row.id)
        }
        store.history.sort { $0.date > $1.date }

        for row in try await rows("certificates", as: CertRow.self)
        where !store.certs.contains(where: { $0.id == row.id }) && !tombCert.contains(row.id.uuidString) {
            guard let key = vaultKey else { continue } // restored once the vault is unlocked
            do {
                let blob = try await download("\(uid.uuidString)/certs/\(row.id.uuidString).bin")
                let bundle = try JSONDecoder().decode(CertBundle.self, from: VaultCrypto.open(blob, key))
                let cert = CertificateProfile(id: row.id, name: row.name, account: row.account, teamID: row.teamId,
                                              profileName: row.profileName, expires: row.expires,
                                              addedAt: row.addedAt, revoked: row.revoked)
                try FileManager.default.createDirectory(at: cert.folder, withIntermediateDirectories: true)
                try bundle.p12.write(to: cert.p12URL)
                try bundle.profile.write(to: cert.profileURL)
                Keychain.set(bundle.password, for: cert.id)
                store.certs.append(cert)
                mark("cloud.certsUploaded", cert.id)
                if store.selectedCertID == nil { store.selectedCertID = cert.id }
            } catch { status = "Couldn't restore \(row.name): \(error.localizedDescription)" }
        }
    }

    private func restoreFile(_ item: LibraryItem, hasFile: Bool, uid: UUID) async {
        if hasFile, let data = try? await download("\(uid.uuidString)/ipa/\(item.id.uuidString).ipa", to: item.fileURL) {
            _ = data; return
        }
        if let s = item.sourceURL, let url = URL(string: s),
           let (tmp, resp) = try? await URLSession.shared.download(from: url),
           (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
            try? FileManager.default.removeItem(at: item.fileURL)
            try? FileManager.default.moveItem(at: tmp, to: item.fileURL)
        }
    }

    // MARK: Push (device → cloud)

    private func push(store: AppStore, uid: UUID, backupIPAs: Bool) async throws {
        // Deletions first.
        for table in [Tombstones.Table.library, .certs, .history] {
            let ids = Tombstones.list(table)
            guard !ids.isEmpty else { continue }
            try await api("DELETE", "rest/v1/\(table.rawValue)",
                          query: [URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))")])
            for id in ids {
                switch table {
                case .library: _ = try? await api("DELETE", "storage/v1/object/\(CloudConfig.bucket)/\(uid.uuidString)/ipa/\(id).ipa")
                case .certs: _ = try? await api("DELETE", "storage/v1/object/\(CloudConfig.bucket)/\(uid.uuidString)/certs/\(id).bin")
                case .history: break
                }
            }
            Tombstones.clear(table, ids)
        }

        // IPA files first so the row can say whether a file exists.
        var uploaded = marked("cloud.ipaUploaded")
        if backupIPAs {
            for item in store.library where item.hasLocalFile && !uploaded.contains(item.id.uuidString) {
                guard item.size <= Self.maxUploadBytes else { continue }
                status = "Backing up \(item.name)…"
                if (try? await upload(item.fileURL, to: "\(uid.uuidString)/ipa/\(item.id.uuidString).ipa")) != nil {
                    mark("cloud.ipaUploaded", item.id)
                    uploaded.insert(item.id.uuidString)
                }
            }
        }

        let lib = store.library.map {
            LibraryRow(id: $0.id, name: $0.name, bundleId: $0.bundleID, version: $0.version, size: $0.size,
                       sourceUrl: $0.sourceURL, hasFile: uploaded.contains($0.id.uuidString), addedAt: $0.addedAt)
        }
        try await upsert("library_items", lib)

        let pushed = marked("cloud.historyPushed")
        let hist = store.history.filter { !pushed.contains($0.id.uuidString) }.map {
            HistoryRow(id: $0.id, date: $0.date, appName: $0.appName, bundleId: $0.bundleID, version: $0.version,
                       certName: $0.certName, success: $0.success, message: $0.message, duration: $0.duration,
                       libraryId: $0.libraryID)
        }
        try await upsert("sign_history", hist)
        hist.forEach { mark("cloud.historyPushed", $0.id) }

        // Certificates: metadata always, encrypted files only once the vault is unlocked.
        let certsUp = marked("cloud.certsUploaded")
        var certRows: [CertRow] = []
        for cert in store.certs {
            if let key = vaultKey, !certsUp.contains(cert.id.uuidString),
               let p12 = try? Data(contentsOf: cert.p12URL), let prof = try? Data(contentsOf: cert.profileURL) {
                let bundle = CertBundle(p12: p12, profile: prof, password: Keychain.get(cert.id))
                let sealed = try VaultCrypto.seal(JSONEncoder().encode(bundle), key)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try sealed.write(to: tmp)
                defer { try? FileManager.default.removeItem(at: tmp) }
                try await upload(tmp, to: "\(uid.uuidString)/certs/\(cert.id.uuidString).bin")
                mark("cloud.certsUploaded", cert.id)
            }
            // Only advertise certs whose encrypted files are actually in the cloud.
            if marked("cloud.certsUploaded").contains(cert.id.uuidString) {
                certRows.append(CertRow(id: cert.id, name: cert.name, account: cert.account, teamId: cert.teamID,
                                        profileName: cert.profileName, expires: cert.expires, revoked: cert.revoked,
                                        addedAt: cert.addedAt))
            }
        }
        try await upsert("certificates", certRows)
    }

    private func upsert<T: Encodable>(_ table: String, _ rows: [T]) async throws {
        guard !rows.isEmpty else { return }
        try await api("POST", "rest/v1/\(table)", query: [URLQueryItem(name: "on_conflict", value: "id")],
                      body: CloudDates.encoder.encode(rows),
                      extra: ["Prefer": "resolution=merge-duplicates,return=minimal"])
    }

    // MARK: Storage

    private func upload(_ file: URL, to path: String) async throws {
        var req = try await request("POST", "storage/v1/object/\(CloudConfig.bucket)/\(path)",
                                    contentType: "application/octet-stream", extra: ["x-upsert": "true"])
        req.httpMethod = "POST"
        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
        try Cloud.check(data, resp)
    }

    @discardableResult
    private func download(_ path: String, to dest: URL? = nil) async throws -> Data {
        let req = try await request("GET", "storage/v1/object/authenticated/\(CloudConfig.bucket)/\(path)")
        if let dest {
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            try Cloud.check((try? Data(contentsOf: tmp, options: .mappedIfSafe).prefix(512)).map { Data($0) } ?? Data(), resp)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return Data()
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Cloud.check(data, resp)
        return data
    }
}
