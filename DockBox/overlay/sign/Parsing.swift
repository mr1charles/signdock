import Foundation

struct IPAInfo { var name: String; var bundleID: String; var version: String }

enum IPAError: LocalizedError {
    case notAnIPA, unreadable
    var errorDescription: String? {
        switch self {
        case .notAnIPA: return "Not a valid IPA (no Payload/*.app found)."
        case .unreadable: return "The app's Info.plist couldn't be read."
        }
    }
}

enum IPAInspector {
    static func inspect(_ url: URL) throws -> IPAInfo {
        guard let archive = try? Archive(url: url, accessMode: .read) else { throw IPAError.notAnIPA }
        let pattern = #"^Payload/[^/]+\.app/Info\.plist$"#
        guard let entry = archive.first(where: { $0.path.range(of: pattern, options: .regularExpression) != nil })
        else { throw IPAError.notAnIPA }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String else { throw IPAError.unreadable }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? bundleID
        let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String) ?? "?"
        return IPAInfo(name: name, bundleID: bundleID, version: version)
    }
}

struct ProvisionInfo {
    var name: String; var teamID: String; var expires: Date?
    var entitlementKeys: Set<String> = []
    var grantsMoreMemory: Bool { entitlementKeys.contains(ProvisionParser.increasedMemoryKey) }
}

enum ProvisionParser {
    static let increasedMemoryKey = "com.apple.developer.kernel.increased-memory-limit"

    /// A .mobileprovision is CMS-wrapped, but the plist inside is stored in the clear.
    static func parse(_ data: Data) -> ProvisionInfo? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else { return nil }
        let plistData = data[start.lowerBound..<end.upperBound]
        guard let dict = (try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)) as? [String: Any]
        else { return nil }
        let team = (dict["TeamIdentifier"] as? [String])?.first ?? ""
        let ents = (dict["Entitlements"] as? [String: Any]).map { Set($0.keys) } ?? []
        return ProvisionInfo(name: dict["Name"] as? String ?? "Profile", teamID: team,
                             expires: dict["ExpirationDate"] as? Date, entitlementKeys: ents)
    }
}
