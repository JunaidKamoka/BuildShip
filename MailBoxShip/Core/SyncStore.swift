import Foundation
import SwiftUI

/// Drives cross-machine sync and holds its visible state.
///
/// Identity — the Firebase refresh token and uid — lives in UserDefaults, not
/// in the synced data file: it is the bootstrap that *fetches* that file, so it
/// cannot live inside it. A second Mac joins by redeeming a pairing code (the
/// first machine's refresh token), after which both push and pull the one
/// `mailboxship/{uid}` document.
@MainActor
final class SyncStore: ObservableObject {
    @Published private(set) var available = Deployment.syncConfigured
    @Published private(set) var signedIn = false
    @Published private(set) var uid = ""
    @Published private(set) var busy = false
    @Published var status = ""

    /// Called after a successful pull, so the profile list reloads from the
    /// freshly written data file.
    var onDidPull: () -> Void = {}

    private let sync = FirebaseSync(
        apiKey: Deployment.firebaseAPIKey, projectID: Deployment.firebaseProjectID)
    private var session: FirebaseSync.Session?

    private static let refreshKey = "syncRefreshToken"
    private static let uidKey = "syncUID"

    private var storedRefreshToken: String? {
        get { UserDefaults.standard.string(forKey: Self.refreshKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.refreshKey) }
    }

    init() {
        uid = UserDefaults.standard.string(forKey: Self.uidKey) ?? ""
        signedIn = !(storedRefreshToken ?? "").isEmpty
    }

    // MARK: - Session

    /// A live session, signing up anonymously the first time and refreshing the
    /// stored identity thereafter.
    @discardableResult
    private func ensureSession() async throws -> FirebaseSync.Session {
        if let session { return session }
        let resolved = try await (storedRefreshToken?.isEmpty == false
            ? sync.refresh(refreshToken: storedRefreshToken!)
            : sync.signUpAnonymously())
        persist(resolved)
        return resolved
    }

    private func persist(_ resolved: FirebaseSync.Session) {
        session = resolved
        storedRefreshToken = resolved.refreshToken
        uid = resolved.uid
        UserDefaults.standard.set(resolved.uid, forKey: Self.uidKey)
        signedIn = true
    }

    func signOut() {
        session = nil
        signedIn = false
        storedRefreshToken = nil
        uid = ""
        UserDefaults.standard.removeObject(forKey: Self.uidKey)
        status = "Signed out."
    }

    // MARK: - Pairing

    /// A code that carries this machine's identity to another Mac. Base64 of a
    /// tiny JSON blob; whoever redeems it shares this uid and its document.
    func pairingCode() async -> String? {
        guard (try? await ensureSession()) != nil,
              let token = storedRefreshToken, !token.isEmpty else { return nil }
        let blob = ["r": token, "u": uid]
        guard let data = try? JSONSerialization.data(withJSONObject: blob) else { return nil }
        return data.base64EncodedString()
    }

    /// Adopt an identity from another Mac's pairing code, then pull its data.
    func redeem(pairingCode code: String) {
        run("Pairing…") {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: trimmed),
                  let blob = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let token = blob["r"], !token.isEmpty
            else { throw ShipError("That pairing code could not be read.") }

            let resolved = try await self.sync.refresh(refreshToken: token)
            self.persist(resolved)
            try await self.pull(using: resolved)
            self.status = "Paired with \(blob["u"]?.prefix(6) ?? "another Mac") and pulled."
        }
    }

    // MARK: - Push / Pull

    func pushNow() { run("Pushing…") { try await self.push(using: try await self.ensureSession()) } }
    func pullNow() { run("Pulling…") { try await self.pull(using: try await self.ensureSession()) } }

    private func push(using session: FirebaseSync.Session) async throws {
        let document = SecretStore.shared.snapshot()

        // Gather every referenced key file by base name, so a machine that
        // pulls can rebuild them wherever it keeps its data.
        var files: [String: String] = [:]
        for profile in document.profiles {
            for path in [profile.keyPath, profile.identityPath] where !path.isEmpty {
                if let data = FileManager.default.contents(atPath: path) {
                    files[(path as NSString).lastPathComponent] = data.base64EncodedString()
                }
            }
        }

        let documentJSON = String(
            data: (try? JSONEncoder().encode(document)) ?? Data(), encoding: .utf8) ?? "{}"
        let filesJSON = String(
            data: (try? JSONSerialization.data(withJSONObject: files)) ?? Data(),
            encoding: .utf8) ?? "{}"
        let errors = (try? String(
            contentsOfFile: ErrorLog.path(folder: SecretStore.shared.folder),
            encoding: .utf8)) ?? ""

        try await sync.save(FirebaseSync.Payload(
            document: documentJSON, files: filesJSON, errorLog: errors,
            updatedAt: Self.timestamp(), updatedBy: ProcessInfo.processInfo.hostName),
            session: session)
        status = "Pushed \(document.profiles.count) profile(s) and \(files.count) key file(s)."
    }

    private func pull(using session: FirebaseSync.Session) async throws {
        guard let payload = try await sync.fetch(session: session) else {
            status = "Nothing to pull yet — this identity has never pushed."
            return
        }

        // Materialise the key files beside the data file and repoint every
        // profile at the local copies, so their paths are valid on this Mac.
        let keysFolder = (SecretStore.shared.folder as NSString).appendingPathComponent("keys")
        try? FileManager.default.createDirectory(
            atPath: keysFolder, withIntermediateDirectories: true)

        var localByName: [String: String] = [:]
        if let filesData = payload.files.data(using: .utf8),
           let files = try? JSONSerialization.jsonObject(with: filesData) as? [String: String] {
            for (name, base64) in files {
                guard let bytes = Data(base64Encoded: base64) else { continue }
                let dest = (keysFolder as NSString).appendingPathComponent(name)
                try? bytes.write(to: URL(fileURLWithPath: dest))
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: dest)
                localByName[name] = dest
            }
        }

        guard let documentData = payload.document.data(using: .utf8),
              var document = try? JSONDecoder().decode(ShipDocument.self, from: documentData)
        else { throw ShipError("The pulled data file could not be read.") }

        for index in document.profiles.indices {
            let keyName = (document.profiles[index].keyPath as NSString).lastPathComponent
            let idName = (document.profiles[index].identityPath as NSString).lastPathComponent
            if let local = localByName[keyName] { document.profiles[index].keyPath = local }
            if let local = localByName[idName] { document.profiles[index].identityPath = local }
        }

        SecretStore.shared.adopt(document)
        if !payload.errorLog.isEmpty {
            try? payload.errorLog.write(
                toFile: ErrorLog.path(folder: SecretStore.shared.folder),
                atomically: true, encoding: .utf8)
        }
        onDidPull()

        let from = payload.updatedBy.isEmpty ? "another Mac" : payload.updatedBy
        status = "Pulled \(document.profiles.count) profile(s) and "
            + "\(localByName.count) key file(s) from \(from)."
    }

    // MARK: - Helpers

    /// Runs an async job with the busy flag and error-to-status handling every
    /// action shares.
    private func run(_ initial: String, _ work: @escaping () async throws -> Void) {
        guard available, !busy else { return }
        busy = true
        status = initial
        Task { @MainActor in
            do { try await work() }
            catch { status = (error as? ShipError)?.message ?? error.localizedDescription }
            busy = false
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
