import Foundation

/// Everything the app knows, in one JSON file you own.
///
/// Deliberately **not** inside the app bundle or its container: deleting or
/// replacing MailBoxShip.app must not take your stores, keys and passwords with
/// it. The file lives in your Documents folder by default, is created on first
/// use, and is picked up again by any later install. Point it somewhere else —
/// a project folder, an encrypted volume, a removable disk — and that location
/// becomes the source of truth instead.
///
/// No Keychain is used. That is a constraint with a real cost: this is a
/// plaintext file, readable by anything running as you, where the Keychain
/// would have encrypted it at rest. What it buys is visibility and control —
/// you can read exactly what is stored, move it, back it up, and delete it all
/// in one action.
struct ShipDocument: Codable {
    var profiles: [ShipProfile] = []
    /// Proxy and demo-account passwords, keyed by owner.
    var secrets: [String: String] = [:]
}

@MainActor
final class SecretStore: ObservableObject {
    static let shared = SecretStore()

    @Published private(set) var path: String
    private var document = ShipDocument()

    private static let pathKey = "shipDataPath"

    /// Default home: visible, outside the app container, and untouched by
    /// deleting the app.
    static var defaultPath: String {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MailBoxShip", isDirectory: true)
        return documents.appendingPathComponent("ship.json").path
    }

    private init() {
        path = UserDefaults.standard.string(forKey: Self.pathKey) ?? Self.defaultPath
        load()
    }

    var summary: String { path }
    var folder: String { (path as NSString).deletingLastPathComponent }

    // MARK: - Location

    /// Move to a different file. An existing file there wins — that is the
    /// point of pointing at it — otherwise the current data is written across.
    func relocate(to newPath: String) {
        let target = newPath.hasSuffix(".json")
            ? newPath
            : (newPath as NSString).appendingPathComponent("ship.json")

        UserDefaults.standard.set(target, forKey: Self.pathKey)
        path = target

        if FileManager.default.fileExists(atPath: target) {
            load()
        } else {
            save()
        }
    }

    // MARK: - Profiles

    var profiles: [ShipProfile] {
        get { document.profiles }
        set { document.profiles = newValue; save() }
    }

    // MARK: - Whole-document access (cloud sync)

    /// The entire document, for the sync engine to serialise and upload.
    func snapshot() -> ShipDocument { document }

    /// Replace the whole document with a pulled one and persist it. The caller
    /// is expected to reload any view state (the profile list) afterwards.
    func adopt(_ newDocument: ShipDocument) {
        document = newDocument
        save()
    }

    // MARK: - Secrets

    func get(_ key: String) -> String { document.secrets[key] ?? "" }

    func set(_ value: String, for key: String) {
        if value.isEmpty { document.secrets.removeValue(forKey: key) }
        else { document.secrets[key] = value }
        save()
    }

    func delete(_ key: String) {
        document.secrets.removeValue(forKey: key)
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = FileManager.default.contents(atPath: path) else {
            // Nothing there yet. Carry over an older install's profiles rather
            // than silently starting empty.
            migrateLegacyProfiles()
            save()
            return
        }
        do {
            document = try JSONDecoder().decode(ShipDocument.self, from: data)
        } catch {
            // Keep the original. Overwriting an unreadable file with an empty
            // one destroys the only copy of the user's setup, which is a far
            // worse outcome than starting blank this once.
            let backup = path + ".unreadable-\(Int(Date().timeIntervalSince1970))"
            try? FileManager.default.copyItem(atPath: path, toPath: backup)
            NSLog("MailBoxShip: could not read \(path) (\(error)); kept a copy at \(backup)")
            document = ShipDocument()
        }
    }

    /// Earlier builds kept profiles in Application Support and secrets in the
    /// Keychain. Profiles are worth carrying forward; the Keychain items are
    /// deliberately left behind, since removing that dependency is the point.
    private func migrateLegacyProfiles() {
        let legacy = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MailBoxShip/profiles.json")

        guard
            let data = try? Data(contentsOf: legacy),
            let profiles = try? JSONDecoder().decode([ShipProfile].self, from: data),
            !profiles.isEmpty
        else { return }

        document.profiles = profiles
        NSLog("MailBoxShip: carried \(profiles.count) profile(s) forward from Application Support")
    }

    private func save() {
        let directory = folder
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: URL(fileURLWithPath: path), options: .atomic)

            // Owner-only. It cannot make a plaintext file safe, but it does keep
            // other accounts on this Mac out of it.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            NSLog("MailBoxShip: could not write \(path) — \(error.localizedDescription)")
        }
    }
}
