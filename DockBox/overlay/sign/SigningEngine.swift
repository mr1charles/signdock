import Foundation

enum SigningError: LocalizedError {
    case noApp, signFailed, noMemoryEntitlement, noSpace(String)
    var errorDescription: String? {
        switch self {
        case .noApp: return "No .app found inside the IPA."
        case .noSpace(let needed): return "Not enough free storage. Signing this app needs about \(needed)."
        case .noMemoryEntitlement:
            return "This certificate's profile doesn't include the Increased Memory Limit entitlement. Generate the profile with that capability enabled, or turn the option off."
        case .signFailed:
            return "Signing failed. Check the p12 password, that the profile belongs to this certificate, and that the app's bundle ID is allowed by the profile."
        }
    }
}

enum SigningEngine {
    struct Output { var url: URL; var bundleID: String }

    /// Blocking; call off the main thread. Zsign keeps global state, so never run two at once.
    static func sign(ipa: URL, displayName: String, cert: CertificateProfile,
                     password: String, bundleSuffix: String, requireMoreMemory: Bool = false) throws -> Output {
        if requireMoreMemory {
            let info = (try? Data(contentsOf: cert.profileURL)).flatMap(ProvisionParser.parse)
            guard info?.grantsMoreMemory == true else { throw SigningError.noMemoryEntitlement }
        }
        let fm = FileManager.default
        // Unzipped app plus the new IPA. Compressed apps commonly expand to about three times their size.
        let size = Int64((try? ipa.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let free = (try? fm.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        if let free, free > 0, free < size * 4 {
            throw SigningError.noSpace(ByteCountFormatter.string(fromByteCount: size * 4, countStyle: .file))
        }
        let work = Paths.work()
        defer { try? fm.removeItem(at: work) }

        try fm.unzipItem(at: ipa, to: work)
        let payload = work.appendingPathComponent("Payload")
        guard let appName = try fm.contentsOfDirectory(atPath: payload.path).first(where: { $0.hasSuffix(".app") })
        else { throw SigningError.noApp }
        let app = payload.appendingPathComponent(appName)

        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any]
        let original = plist?["CFBundleIdentifier"] as? String ?? ""
        let suffix = bundleSuffix.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        let newID = suffix.isEmpty ? original : "\(original).\(suffix)"

        var callbackOK = true
        let ran = Zsign.sign(
            appPath: app.path,
            provisionPath: cert.profileURL.path,
            p12Path: cert.p12URL.path,
            p12Password: password,
            customIdentifier: suffix.isEmpty ? "" : newID,
            // In this Zsign fork `true` means "write the profile into the app as embedded.mobileprovision"
            // (the name is inverted). Feather passes `!removeProvisioning`, which is true by default.
            removeProvision: true,
            completion: { callbackOK = $0 }
        )
        guard ran, callbackOK else { throw SigningError.signFailed }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let safe = displayName.replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "_", options: .regularExpression)
        let out = Paths.signed.appendingPathComponent("\(safe)_signed_\(stamp.string(from: Date())).ipa")
        try? fm.removeItem(at: out)
        try fm.zipItem(at: payload, to: out, shouldKeepParent: true, compressionMethod: .deflate)
        return Output(url: out, bundleID: newID)
    }
}

@MainActor
final class BatchSigner: ObservableObject {
    enum State: Equatable { case queued, working, done, failed(String) }
    struct Job: Identifiable {
        let id = UUID()
        let item: LibraryItem
        var state: State = .queued
        var output: URL?
    }

    @Published var jobs: [Job] = []
    @Published var running = false
    var finished: Bool { !jobs.isEmpty && !running }
    var completed: Int { jobs.filter { $0.state == .done || { if case .failed = $0 { return true } else { return false } }($0.state) }.count }

    func run(items: [LibraryItem], cert: CertificateProfile, bundleSuffix: String, requireMoreMemory: Bool, store: AppStore) async {
        guard !running else { return }
        running = true
        jobs = items.map { Job(item: $0) }
        let password = Keychain.get(cert.id)

        for index in jobs.indices {
            let item = jobs[index].item
            guard item.hasLocalFile else {
                jobs[index].state = .failed("This IPA hasn't been downloaded to this device yet. Sync, or re-import it.")
                continue
            }
            jobs[index].state = .working
            await DockBoxMemory.waitForHeadroom()
            let started = Date()
            let result = await Task.detached(priority: .userInitiated) {
                // Drain per app so a long batch doesn't build up temporary objects.
                autoreleasepool {
                    Result { try SigningEngine.sign(ipa: item.fileURL, displayName: item.name, cert: cert,
                                                    password: password, bundleSuffix: bundleSuffix,
                                                    requireMoreMemory: requireMoreMemory) }
                }
            }.value

            var record = SignRecord(appName: item.name, bundleID: item.bundleID, version: item.version,
                                    certName: cert.name, success: false, message: "",
                                    duration: Date().timeIntervalSince(started), libraryID: item.id)
            switch result {
            case .success(let out):
                jobs[index].state = .done
                jobs[index].output = out.url
                record.success = true
                record.bundleID = out.bundleID
                record.outputName = out.url.lastPathComponent
                record.message = "Signed"
            case .failure(let error):
                jobs[index].state = .failed(error.localizedDescription)
                record.message = error.localizedDescription
            }
            store.history.insert(record, at: 0)
        }
        running = false
    }
}
