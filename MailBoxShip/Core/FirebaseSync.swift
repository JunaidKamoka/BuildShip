import Foundation

/// Cross-machine sync over Firebase's REST APIs — no SDK, in the same spirit as
/// `ASCClient`: raw `URLSession` against documented endpoints.
///
/// Identity is a Firebase *anonymous* user. A fresh anonymous sign-up returns a
/// uid unique to that call, which would strand every Mac on its own island; to
/// share one, the refresh token is carried to another Mac as a "pairing code",
/// and each paired machine then reads and writes the same `mailboxship/{uid}`
/// document. Access is gated by Firebase Auth and the Firestore rule scoped to
/// that uid, so the signing keys the document holds stay private to the
/// machines the user has paired.
struct FirebaseSync {
    let apiKey: String
    let projectID: String

    /// An authenticated session. The id token lasts an hour; the refresh token
    /// is long-lived and *is* the portable identity a pairing code carries.
    struct Session: Sendable {
        var idToken: String
        var refreshToken: String
        var uid: String
    }

    /// The synced document, flattened to plain strings so the Firestore REST
    /// payload is one straightforward set of `stringValue` fields.
    struct Payload: Sendable {
        /// `ShipDocument` as JSON — profiles and secrets.
        var document: String
        /// `[filename: base64]` for every `.p8`/`.p12` the profiles reference.
        var files: String
        /// `ship-errors.md`, so failures are legible on any paired machine.
        var errorLog: String
        /// ISO-8601, stamped by whoever wrote last.
        var updatedAt: String
        /// The host that pushed, so "last synced from …" can be shown.
        var updatedBy: String
    }

    // MARK: - Auth

    /// Create a brand-new anonymous identity.
    func signUpAnonymously() async throws -> Session {
        let json = try await postJSON(
            "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(apiKey)",
            body: ["returnSecureToken": true])
        guard let idToken = json["idToken"] as? String,
              let refreshToken = json["refreshToken"] as? String,
              let uid = json["localId"] as? String
        else { throw ShipError("Firebase returned an unreadable sign-in response.") }
        return Session(idToken: idToken, refreshToken: refreshToken, uid: uid)
    }

    /// Trade a refresh token for a fresh id token. This is how a paired machine
    /// (and every relaunch) gets a working session without signing up again.
    func refresh(refreshToken: String) async throws -> Session {
        // The secure-token endpoint answers in snake_case, unlike the rest.
        let json = try await postJSON(
            "https://securetoken.googleapis.com/v1/token?key=\(apiKey)",
            body: ["grant_type": "refresh_token", "refresh_token": refreshToken])
        guard let idToken = json["id_token"] as? String,
              let newRefresh = json["refresh_token"] as? String,
              let uid = json["user_id"] as? String
        else { throw ShipError("Firebase could not refresh the session — pair again.") }
        return Session(idToken: idToken, refreshToken: newRefresh, uid: uid)
    }

    // MARK: - Firestore document

    private var documentRoot: String {
        "https://firestore.googleapis.com/v1/projects/\(projectID)"
        + "/databases/(default)/documents/mailboxship"
    }

    /// Read the sync document, or `nil` when this uid has never pushed.
    func fetch(session: Session) async throws -> Payload? {
        var request = URLRequest(url: try url("\(documentRoot)/\(session.uid)"))
        request.setValue("Bearer \(session.idToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        try Self.check(status: status, data: data)

        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let fields = json["fields"] as? [String: Any] ?? [:]
        func field(_ key: String) -> String {
            ((fields[key] as? [String: Any])?["stringValue"] as? String) ?? ""
        }
        return Payload(
            document: field("document"), files: field("files"),
            errorLog: field("errorLog"), updatedAt: field("updatedAt"),
            updatedBy: field("updatedBy"))
    }

    /// Write the sync document, replacing exactly the fields it owns.
    func save(_ payload: Payload, session: Session) async throws {
        let fieldNames = ["document", "files", "errorLog", "updatedAt", "updatedBy"]
        let mask = fieldNames.map { "updateMask.fieldPaths=\($0)" }.joined(separator: "&")

        var request = URLRequest(url: try url("\(documentRoot)/\(session.uid)?\(mask)"))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(session.idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "fields": [
                "document": ["stringValue": payload.document],
                "files": ["stringValue": payload.files],
                "errorLog": ["stringValue": payload.errorLog],
                "updatedAt": ["stringValue": payload.updatedAt],
                "updatedBy": ["stringValue": payload.updatedBy],
            ],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }

    // MARK: - Plumbing

    private func url(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw ShipError("Bad Firebase URL") }
        return url
    }

    private func postJSON(_ string: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: try url(string))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Turn Firebase's structured error into one readable sentence.
    private static func check(status: Int, data: Data) throws {
        guard !(200..<300).contains(status) else { return }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
        // The commonest first-run stumble: the provider is off in the console.
        if message.contains("ADMIN_ONLY_OPERATION") || message.contains("OPERATION_NOT_ALLOWED") {
            throw ShipError("Anonymous sign-in is disabled for this Firebase project. "
                + "Enable it in the console: Authentication → Sign-in method → Anonymous.")
        }
        throw ShipError("Firebase: \(message)")
    }
}
