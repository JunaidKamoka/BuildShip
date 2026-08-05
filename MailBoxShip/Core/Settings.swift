import Foundation
import SwiftUI

/// Persisted form values.
///
/// Paths and identifiers only. The `.p8` itself is never copied, never read
/// into this object and never stored — the app keeps a path and opens the file
/// at the moment it needs to sign a token. Key IDs and issuer IDs are
/// identifiers rather than secrets, so UserDefaults is the right home for them;
/// the private key stays exactly where the user put it.
@MainActor
final class Settings: ObservableObject {

    @AppStorage("projectPath") var projectPath = ""
    @AppStorage("scheme") var scheme = ""
    @AppStorage("bundleID") var bundleID = ""
    @AppStorage("extensionBundleIDs") var extensionBundleIDsRaw = ""
    @AppStorage("keyPath") var keyPath = ""
    @AppStorage("keyID") var keyID = ""
    @AppStorage("issuerID") var issuerID = ""
    @AppStorage("marketingVersion") var marketingVersion = ""
    @AppStorage("buildNumber") var buildNumber = ""

    var extensionBundleIDs: [String] {
        extensionBundleIDsRaw
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// What is still missing, phrased as the thing to do rather than the field
    /// that is empty.
    func problems() -> [String] {
        var out: [String] = []
        if projectPath.isEmpty { out.append("Choose your .xcodeproj") }
        else if !FileManager.default.fileExists(atPath: projectPath) {
            out.append("That project path no longer exists")
        }
        if scheme.isEmpty { out.append("Enter the scheme name") }
        if bundleID.isEmpty { out.append("Enter the app's bundle identifier") }
        if keyPath.isEmpty { out.append("Choose your App Store Connect .p8 key") }
        else if !FileManager.default.fileExists(atPath: keyPath) {
            out.append("That .p8 file no longer exists")
        }
        if keyID.isEmpty { out.append("Enter the Key ID") }
        if issuerID.isEmpty { out.append("Enter the Issuer ID") }
        return out
    }

    /// Key IDs are exactly ten characters; catching it here saves a round trip
    /// that would otherwise fail with an unexplained 401.
    var keyIDLooksWrong: Bool {
        !keyID.isEmpty && keyID.count != 10
    }

    /// Issuer IDs are UUIDs. Pasting the Key ID into this field is the single
    /// most common setup mistake.
    var issuerLooksWrong: Bool {
        !issuerID.isEmpty && UUID(uuidString: issuerID) == nil
    }

    /// Infer the Key ID from the conventional filename, so one fewer field has
    /// to be copied by hand.
    func adoptKey(path: String) {
        keyPath = path
        let name = (path as NSString).lastPathComponent
        if keyID.isEmpty, name.hasPrefix("AuthKey_"), name.hasSuffix(".p8") {
            keyID = String(name.dropFirst("AuthKey_".count).dropLast(".p8".count))
        }
    }
}
