import Foundation
import CryptoKit

/// App Store Connect API client.
///
/// Every signing asset this tool needs — the team id, the distribution
/// certificate, the App ID, the provisioning profiles — is obtained from this
/// API using nothing but the `.p8` key. That is the whole point: no Apple ID
/// is signed in, no account is added to Xcode, and no identity belonging to
/// this machine is involved at any stage.
///
/// It also sidesteps Xcode's *cloud signing* service, which refuses App Store
/// Connect API keys with a bare "Cloud signing permission error". Requesting a
/// CSR-based certificate and naming profiles explicitly avoids that path
/// entirely.
struct ASCClient {
    let keyID: String
    let issuerID: String
    /// Path only. The key is read at the moment of signing and never retained.
    let privateKeyPath: String
    /// Pre-resolved proxy settings, if the network requires one.
    var proxyDictionary: [AnyHashable: Any]?

    private let base = "https://api.appstoreconnect.apple.com"
 
    /// A session per client, so a proxy applies to these calls without
    /// touching `URLSession.shared` — which other parts of the app use.
    private var session: URLSession {
        guard let dictionary = proxyDictionary else { return .shared }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = dictionary
        return URLSession(configuration: configuration)
    }

    // MARK: - Auth

    /// Mint a short-lived ES256 JWT.
    ///
    /// Ten minutes because Apple rejects anything longer than twenty, and a
    /// short life limits the damage if a token is ever captured in a log.
    private func token() throws -> String {
        let pem = try String(contentsOfFile: privateKeyPath, encoding: .utf8)

        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw ShipError(
                "That file could not be read as an App Store Connect key. "
                + "It should be the .p8 downloaded from App Store Connect, "
                + "beginning with -----BEGIN PRIVATE KEY-----."
            )
        }

        let header = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let now = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "iss": issuerID,
            "iat": now,
            "exp": now + 600,
            "aud": "appstoreconnect-v1",
        ]

        let signingInput = "\(try b64(header)).\(try b64(payload))"
        // `rawRepresentation` is r||s, which is exactly the concatenated form
        // JWS requires. DER — what most signing APIs return by default — is
        // rejected by Apple with an opaque 401.
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(signature.rawRepresentation.base64URL)"
    }

    private func b64(_ object: Any) throws -> String {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).base64URL
    }

    // MARK: - Requests

    @discardableResult
    private func request(
        _ method: String, _ path: String, body: [String: Any]? = nil,
    ) async throws -> [String: Any] {
        // `path` is normally relative and gets the base prepended; Apple's
        // pagination `links.next`, though, is a full absolute URL, so pass
        // those straight through untouched.
        guard let url = URL(string: path.hasPrefix("http") ? path : base + path) else {
            throw ShipError("Bad URL: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(status) else {
            throw ShipError("\(method) \(path) failed (\(status)): \(Self.describe(data))")
        }
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Every item of a list endpoint, following Apple's `links.next` cursor to
    /// the end.
    ///
    /// A list response caps at its `limit` — 200 at most — and hides the rest
    /// behind an opaque cursor. Reading only the first page silently truncates
    /// the account: on a team with more than 200 registered App IDs, one past
    /// the first page is invisible, so a lookup reports it missing, the caller
    /// tries to *create* the App ID that already exists, Apple returns 409, and
    /// it surfaces as "belongs to a different team". Following the cursor is
    /// what makes a lookup correct regardless of how large the account is.
    private func requestAll(_ path: String) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var next: String? = path
        while let page = next {
            let json = try await request("GET", page)
            items += (json["data"] as? [[String: Any]]) ?? []
            // `next` is a full absolute URL; `request` passes it through as-is.
            next = (json["links"] as? [String: Any])?["next"] as? String
        }
        return items
    }

    /// Apple's errors are structured; surfacing `detail` is the difference
    /// between an actionable message and a bare status code.
    private static func describe(_ data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let errors = json["errors"] as? [[String: Any]]
        else { return String(data: data, encoding: .utf8)?.prefix(300).description ?? "unknown" }

        return errors.map { e in
            [e["title"], e["detail"]].compactMap { $0 as? String }.joined(separator: " — ")
        }.joined(separator: "; ")
    }

    // MARK: - Team

    /// The team id, read from any registered App ID's seed.
    ///
    /// Derived rather than typed in: a wrong team id fails deep inside
    /// xcodebuild with "No Account for Team", which reads like a missing login
    /// and sends people to add an Apple ID — the one thing this tool exists to
    /// avoid.
    func teamID() async throws -> String {
        let json = try await request("GET", "/v1/bundleIds?limit=200")
        let data = json["data"] as? [[String: Any]] ?? []
        for item in data {
            let attrs = item["attributes"] as? [String: Any]
            if let seed = attrs?["seedId"] as? String, !seed.isEmpty { return seed }
        }
        throw ShipError(
            "Could not determine the team id — this account has no registered "
            + "App IDs yet. Create the app in App Store Connect first."
        )
    }

    // MARK: - Bundle IDs

    /// Resource id for an App ID, registering it only if it genuinely does not
    /// exist yet.
    ///
    /// The lookup is done twice for a reason. Apple's `filter[identifier]` is
    /// exact-match and unforgiving: percent-encoding the dots in a bundle id
    /// makes it silently match nothing, and the caller then tries to *create*
    /// an App ID that already exists and gets a flat 409. Scanning the full
    /// list is the fallback that makes this correct regardless of how the
    /// server treats the filter.
    func bundleID(
        identifier: String, name: String, seedID: String, platform: String = "IOS",
    ) async throws -> String {
        if let existing = try await findBundleID(identifier) { return existing }

        do {
            let made = try await request("POST", "/v1/bundleIds", body: [
                "data": [
                    "type": "bundleIds",
                    "attributes": [
                        "identifier": identifier,
                        "name": name,
                        "platform": platform,
                        "seedId": seedID,
                    ],
                ],
            ])
            guard let id = (made["data"] as? [String: Any])?["id"] as? String else {
                throw ShipError("Registered \(identifier) but got no id back")
            }
            return id
        } catch let error as ShipError where error.message.contains("409")
            || error.message.localizedCaseInsensitiveContains("not available") {
            // It exists after all — either the filter missed it or another
            // process registered it in between. Find it rather than failing.
            if let existing = try await findBundleID(identifier, force: true) { return existing }
            // Registered globally, invisible to this team: it belongs to a
            // different team. Typed, because the caller can sometimes resolve
            // this on its own — an embedded target can ship under a renamed id,
            // only the host app's identity is immovable.
            throw ForeignTeamBundleID(identifier: identifier)
        }
    }

    /// An App ID that exists on Apple's side but under some other team, so this
    /// key can neither use nor register it.
    struct ForeignTeamBundleID: Error {
        let identifier: String
    }

    /// Every build number ever uploaded for an app *on one platform*, following
    /// the cursor to the end — the first page holds the *newest* uploads, and
    /// the highest number is not necessarily among them.
    ///
    /// The platform filter is not optional. One app record can hold an iOS and
    /// a macOS app, and their build numbers are counted separately: a Mac run
    /// that reads the iOS numbers picks one Apple has never seen on the Mac
    /// side, skipping the whole sequence, or worse adopts a number the Mac
    /// train already used and is rejected at validation.
    func allBuildNumbers(appID: String, platform: String) async -> [Int] {
        await buildNumberStrings(appID: appID, platform: platform).compactMap(Int.init)
    }

    /// Build numbers as Apple stores them — strings, since a project is free to
    /// use "1.2.3" where this tool assumes an integer.
    func buildNumberStrings(appID: String, platform: String) async -> [String] {
        let items = (try? await requestAll(
            "/v1/builds?filter[app]=\(appID)"
            + "&filter[preReleaseVersion.platform]=\(platform)&limit=200")) ?? []
        return items.compactMap {
            ($0["attributes"] as? [String: Any])?["version"] as? String
        }
    }

    /// Every App Store version of an app on one platform with its state — what
    /// decides whether a version string is still open for new builds or its
    /// train has closed. Platform-filtered for the same reason build numbers
    /// are: the iOS and macOS sides of one record have independent trains.
    func appStoreVersionStrings(
        appID: String, platform: String,
    ) async throws -> [(version: String, state: String)] {
        let items = try await requestAll(
            "/v1/apps/\(appID)/appStoreVersions?filter[platform]=\(platform)&limit=200")
        return items.compactMap {
            guard let attributes = $0["attributes"] as? [String: Any],
                  let version = attributes["versionString"] as? String
            else { return nil }
            return (version, attributes["appStoreState"] as? String
                    ?? attributes["appVersionState"] as? String ?? "")
        }
    }

    /// The platforms an app record actually holds — "IOS", "MAC_OS", "TV_OS".
    ///
    /// Creating a record for a platform also creates that platform's first 1.0
    /// version, so the set of version platforms is the set of platforms the
    /// record can accept a build for. Worth asking before a build starts: a
    /// package delivered against a platform the record does not have is taken
    /// by the upload service and then discarded, which looks from here like a
    /// clean upload that never appears.
    func recordPlatforms(appID: String) async -> Set<String> {
        let items = (try? await requestAll(
            "/v1/apps/\(appID)/appStoreVersions?limit=200")) ?? []
        return Set(items.compactMap {
            ($0["attributes"] as? [String: Any])?["platform"] as? String
        })
    }

    /// Exact-match lookup, falling back to a full scan.
    private func findBundleID(_ identifier: String, force: Bool = false) async throws -> String? {
        // Bundle identifiers are only letters, digits, dots and hyphens — all
        // legal in a query value. Encoding the dots is what broke this.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_~"))
        let escaped = identifier.addingPercentEncoding(withAllowedCharacters: allowed) ?? identifier

        if !force {
            let filtered = try await request(
                "GET", "/v1/bundleIds?filter[identifier]=\(escaped)&limit=200")
            if let id = match(identifier, in: filtered) { return id }
        }

        // Full scan, following Apple's cursor to the end — `limit=200` is the
        // largest page, and on an account with more App IDs than that the one
        // being looked up can sit on a later page. Stopping at the first page
        // would report an App ID that plainly exists as missing.
        let all = try await requestAll("/v1/bundleIds?limit=200")
        return match(identifier, in: all)
    }

    private func match(_ identifier: String, in response: [String: Any]) -> String? {
        match(identifier, in: response["data"] as? [[String: Any]] ?? [])
    }

    private func match(_ identifier: String, in items: [[String: Any]]) -> String? {
        for item in items {
            let attrs = item["attributes"] as? [String: Any]
            if attrs?["identifier"] as? String == identifier, let id = item["id"] as? String {
                return id
            }
        }
        return nil
    }

    /// Turn on a capability, treating "already enabled" as success.
    ///
    /// Push in particular must be on the App ID before the profile is issued.
    /// A profile built from an App ID without it silently omits
    /// `aps-environment`, and push then fails at runtime with nothing in the
    /// build to explain why.
    func enableCapability(_ capability: String, bundleIDResource: String) async {
        _ = try? await request("POST", "/v1/bundleIdCapabilities", body: [
            "data": [
                "type": "bundleIdCapabilities",
                "attributes": ["capabilityType": capability],
                "relationships": [
                    "bundleId": ["data": ["type": "bundleIds", "id": bundleIDResource]],
                ],
            ],
        ])
    }

    // MARK: - Certificates

    struct Certificate {
        let id: String
        let serialNumber: String
        let displayName: String
        /// Base64 DER.
        let content: String
        /// Used to pick the oldest when the account is at Apple's limit.
        let expirationDate: String
    }

    func certificates(type: String) async throws -> [Certificate] {
        let json = try await request("GET", "/v1/certificates?limit=200")
        return (json["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard
                let id = item["id"] as? String,
                let a = item["attributes"] as? [String: Any],
                a["certificateType"] as? String == type
            else { return nil }
            return Certificate(
                id: id,
                serialNumber: (a["serialNumber"] as? String ?? "").uppercased(),
                displayName: a["displayName"] as? String ?? "",
                content: a["certificateContent"] as? String ?? "",
                expirationDate: a["expirationDate"] as? String ?? "",
            )
        }
    }

    func createCertificate(type: String, csr: String) async throws -> Certificate {
        let json = try await request("POST", "/v1/certificates", body: [
            "data": [
                "type": "certificates",
                "attributes": ["certificateType": type, "csrContent": csr],
            ],
        ])
        guard
            let d = json["data"] as? [String: Any],
            let id = d["id"] as? String,
            let a = d["attributes"] as? [String: Any]
        else { throw ShipError("Certificate created but the response was unreadable") }

        return Certificate(
            id: id,
            serialNumber: (a["serialNumber"] as? String ?? "").uppercased(),
            displayName: a["displayName"] as? String ?? "",
            content: a["certificateContent"] as? String ?? "",
            expirationDate: a["expirationDate"] as? String ?? "",
        )
    }

    func revokeCertificate(id: String) async throws {
        try await request("DELETE", "/v1/certificates/\(id)")
    }

    // MARK: - Profiles

    struct Profile {
        let id: String
        let name: String
        let uuid: String
        /// Base64 `.mobileprovision`.
        let content: String
    }

    func createProfile(
        name: String, type: String, bundleIDResource: String, certificateID: String,
    ) async throws -> Profile {
        let json = try await request("POST", "/v1/profiles", body: [
            "data": [
                "type": "profiles",
                "attributes": ["name": name, "profileType": type],
                "relationships": [
                    "bundleId": ["data": ["type": "bundleIds", "id": bundleIDResource]],
                    "certificates": ["data": [["type": "certificates", "id": certificateID]]],
                ],
            ],
        ])
        guard
            let d = json["data"] as? [String: Any],
            let id = d["id"] as? String,
            let a = d["attributes"] as? [String: Any],
            let content = a["profileContent"] as? String
        else { throw ShipError("Profile created but the response was unreadable") }

        return Profile(
            id: id,
            name: a["name"] as? String ?? name,
            uuid: a["uuid"] as? String ?? UUID().uuidString,
            content: content,
        )
    }
}

// MARK: - Helpers

struct ShipError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Data {
    /// base64url, per RFC 7515 — JWS rejects standard base64 padding.
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - TestFlight

extension ASCClient {

    struct BuildInfo: Identifiable, Hashable {
        let id: String
        let version: String
        /// PROCESSING, VALID, FAILED, INVALID.
        let processingState: String
        let uploaded: String
        var internalState = ""
        var externalState = ""

        /// Internal testers can install as soon as processing finishes; the
        /// public link additionally needs Beta App Review.
        var readyInternally: Bool { internalState == "READY_FOR_BETA_TESTING" }
        var needsReviewSubmission: Bool { externalState == "READY_FOR_BETA_SUBMISSION" }
        var inReview: Bool { externalState.contains("WAITING") || externalState.contains("IN_REVIEW") }
        var approvedExternally: Bool { externalState == "READY_FOR_BETA_TESTING" }
    }

    struct BetaGroup: Identifiable, Hashable {
        let id: String
        let name: String
        let isInternal: Bool
        let publicLinkEnabled: Bool
        let publicLink: String
        var testerCount = 0
    }

    /// Resource id for an app, found by bundle id.
    func appID(bundleID: String) async throws -> String {
        // Paginated: an account can hold more than one page of apps, and the
        // one being shipped is as likely to sit on a later page as the first.
        for item in try await requestAll("/v1/apps?limit=200") {
            let attrs = item["attributes"] as? [String: Any]
            if attrs?["bundleId"] as? String == bundleID, let id = item["id"] as? String {
                return id
            }
        }
        throw ShipError(
            "No app record for \(bundleID) in App Store Connect. "
            + "It has to be created there first — the API cannot create one."
        )
    }

    /// Builds with their TestFlight state.
    ///
    /// `buildBetaDetail` is included rather than fetched per build: the two
    /// states it carries — internal and external — are the whole answer to
    /// "can testers install this yet", and asking separately would be a
    /// request per build.
    func builds(appID: String) async throws -> [BuildInfo] {
        let json = try await request(
            "GET", "/v1/builds?filter[app]=\(appID)&include=buildBetaDetail&limit=20")

        // Map detail id -> states, then attach by relationship.
        var details: [String: (String, String)] = [:]
        for inc in json["included"] as? [[String: Any]] ?? [] {
            guard let id = inc["id"] as? String,
                  let a = inc["attributes"] as? [String: Any] else { continue }
            details[id] = (
                a["internalBuildState"] as? String ?? "",
                a["externalBuildState"] as? String ?? ""
            )
        }

        return (json["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String,
                  let a = item["attributes"] as? [String: Any] else { return nil }

            var build = BuildInfo(
                id: id,
                version: a["version"] as? String ?? "?",
                processingState: a["processingState"] as? String ?? "",
                uploaded: String((a["uploadedDate"] as? String ?? "").prefix(16))
                    .replacingOccurrences(of: "T", with: " "),
            )
            let rel = item["relationships"] as? [String: Any]
            let detail = (rel?["buildBetaDetail"] as? [String: Any])?["data"] as? [String: Any]
            if let detailID = detail?["id"] as? String, let states = details[detailID] {
                build.internalState = states.0
                build.externalState = states.1
            }
            return build
        }
    }

    func betaGroups(appID: String) async throws -> [BetaGroup] {
        let json = try await request("GET", "/v1/apps/\(appID)/betaGroups?limit=50")
        var groups: [BetaGroup] = []

        for item in json["data"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String,
                  let a = item["attributes"] as? [String: Any] else { continue }

            var group = BetaGroup(
                id: id,
                name: a["name"] as? String ?? "(unnamed)",
                isInternal: a["isInternalGroup"] as? Bool ?? false,
                publicLinkEnabled: a["publicLinkEnabled"] as? Bool ?? false,
                publicLink: a["publicLink"] as? String ?? "",
            )
            // Count only; the tester list itself is not something this tool
            // needs to hold.
            if let count = try? await request(
                "GET", "/v1/betaGroups/\(id)/betaTesters?limit=200") {
                group.testerCount = (count["data"] as? [[String: Any]])?.count ?? 0
            }
            groups.append(group)
        }
        return groups
    }

    /// Submit a build for Beta App Review, which is what makes a public link
    /// admit external testers.
    ///
    /// Required once per version; later builds of the same version go straight
    /// through. Internal testing never needs it.
    func submitForBetaReview(buildID: String) async throws {
        try await request("POST", "/v1/betaAppReviewSubmissions", body: [
            "data": [
                "type": "betaAppReviewSubmissions",
                "relationships": ["build": ["data": ["type": "builds", "id": buildID]]],
            ],
        ])
    }
}

// MARK: - Beta App Review details

extension ASCClient {

    /// Contact and demo-account information Apple requires before a build can
    /// go to external testers.
    ///
    /// A demo account is not optional for an app behind a sign-in wall: the
    /// reviewer cannot see past the login screen without one, and the
    /// submission is rejected with little explanation. Setting it here means
    /// the rejection never happens.
    struct ReviewDetail {
        /// Resource id, needed to PATCH.
        let id: String
        var contactFirstName = ""
        var contactLastName = ""
        var contactPhone = ""
        var contactEmail = ""
        var demoAccountName = ""
        var demoAccountRequired = false
        var notes = ""
    }

    func reviewDetail(appID: String) async throws -> ReviewDetail {
        let json = try await request("GET", "/v1/apps/\(appID)/betaAppReviewDetail")
        guard let d = json["data"] as? [String: Any], let id = d["id"] as? String else {
            throw ShipError("This app has no Beta App Review record yet.")
        }
        let a = d["attributes"] as? [String: Any] ?? [:]
        return ReviewDetail(
            id: id,
            contactFirstName: a["contactFirstName"] as? String ?? "",
            contactLastName: a["contactLastName"] as? String ?? "",
            contactPhone: a["contactPhone"] as? String ?? "",
            contactEmail: a["contactEmail"] as? String ?? "",
            demoAccountName: a["demoAccountName"] as? String ?? "",
            demoAccountRequired: a["demoAccountRequired"] as? Bool ?? false,
            notes: a["notes"] as? String ?? "",
        )
    }

    /// The password is passed separately and never stored on the detail struct,
    /// so it cannot be accidentally logged alongside the rest.
    func updateReviewDetail(_ detail: ReviewDetail, demoPassword: String) async throws {
        var attributes: [String: Any] = [
            "contactFirstName": detail.contactFirstName,
            "contactLastName": detail.contactLastName,
            "contactPhone": detail.contactPhone,
            "contactEmail": detail.contactEmail,
            "demoAccountRequired": detail.demoAccountRequired,
            "notes": detail.notes,
        ]
        if detail.demoAccountRequired {
            attributes["demoAccountName"] = detail.demoAccountName
            attributes["demoAccountPassword"] = demoPassword
        }

        try await request("PATCH", "/v1/betaAppReviewDetails/\(detail.id)", body: [
            "data": [
                "type": "betaAppReviewDetails",
                "id": detail.id,
                "attributes": attributes,
            ],
        ])
    }
}



