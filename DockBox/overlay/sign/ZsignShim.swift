import Foundation

/// Swift face for the Zsign C functions compiled into this target (see ZsignBundle/). Adapted from
/// Zsign-Package's swift/zsign.swift (GPL-3.0), which called the same functions through its own module.
enum Zsign {
    /// - Note: In this Zsign fork `removeProvision: true` means "write the profile into the app as
    ///   embedded.mobileprovision"; the name is inverted.
    @discardableResult
    static func sign(
        appPath: String = "", provisionPath: String = "", p12Path: String = "", p12Password: String = "",
        entitlementsPath: String = "", customIdentifier: String = "", customName: String = "",
        customVersion: String = "", adhoc: Bool = false, removeProvision: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) -> Bool {
        zsign(appPath, provisionPath, p12Path, p12Password, entitlementsPath, customIdentifier,
              customName, customVersion, adhoc, removeProvision,
              completion.map { callback in { success in callback(success) } }) == 0
    }

    /// Status 1 means revoked; 2 means it couldn't tell (offline, bad password...).
    static func checkRevokage(provisionPath: String = "", p12Path: String = "", p12Password: String = "",
                              completionHandler: @escaping (Int32, Date?, String?) -> Void) {
        checkCert(provisionPath, p12Path, p12Password) { status, expirationDate, error in
            completionHandler(status, expirationDate, error)
        }
    }
}
