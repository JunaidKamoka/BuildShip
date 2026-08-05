import Foundation

/// The whole path from source to TestFlight, driven only by an App Store
/// Connect API key.
///
/// Ordering here is not cosmetic. Push is enabled on the App ID *before* the
/// profile is issued, because a profile inherits capabilities at creation and
/// one made from an App ID without push silently drops `aps-environment`.
/// Export re-signs the archive rather than trusting it, because `archive`
/// produces a development-signed build whose entitlements are wrong for the
/// store. And validate runs before upload, because an upload permanently
/// consumes a build number.
struct Pipeline {

    enum Configuration: String, CaseIterable, Identifiable {
        case debug = "Debug"
        case release = "Release"
        var id: String { rawValue }

        /// Debug builds go to a device for testing; only Release is uploadable.
        /// The App Store profile type is platform-specific and lives on
        /// `ShipPlatform.profileType(_:)` instead.
        var certificateType: String {
            self == .release ? "DISTRIBUTION" : "DEVELOPMENT"
        }
        var exportMethod: String {
            self == .release ? "app-store-connect" : "development"
        }
        var signingCertificate: String {
            self == .release ? "Apple Distribution" : "Apple Development"
        }
    }

    struct Input {
        var projectPath: String
        var scheme: String
        var configuration: Configuration
        /// iOS unless the scheme builds a Mac app. Determines the archive
        /// destination, the App Store profile type, the App ID platform, and
        /// whether a `.pkg` and an installer certificate are part of the run.
        var platform: ShipPlatform = .iOS
        var bundleID: String
        /// Extra bundle ids embedded in the app (extensions), each needing its
        /// own App ID and profile.
        var extensionBundleIDs: [String]
        var keyPath: String
        var keyID: String
        var issuerID: String
        var marketingVersion: String
        var buildNumber: String
        /// Permit revoking the oldest certificate when Apple refuses a new one.
        ///
        /// Off by default and surfaced as an explicit choice, because revoking
        /// is destructive to whoever else is using that certificate — it can
        /// invalidate provisioning profiles already in use on other machines.
        var allowCertificateReplacement: Bool = false

        /// Resolved entitlements file per bundle id, filled in by detection.
        ///
        /// Needed so each App ID gets exactly the capabilities its own target
        /// declares — enabling the app's push entitlement on an extension that
        /// does not have it is a provisioning error, not a harmless extra.
        var entitlementsByBundleID: [String: String] = [:]

        /// Egress proxy, resolved on the main actor before the run starts, because reading a
        /// password now touches main-actor state and the pipeline itself is not
        /// main-isolated.
        var proxyDictionary: [AnyHashable: Any]?
        var proxyEnvironment: [String: String] = [:]
        var proxyDescription = "direct"

        /// Reusable signing identity (.p12) chosen by the user. Empty means
        /// one will be created and written next to the API key.
        var identityPath: String = ""

        func entitlementsPath(for bundleID: String) -> String {
            entitlementsByBundleID[bundleID] ?? ""
        }
    }

    /// The visible steps of a run.
    ///
    /// Reported separately from the log because a wall of xcodebuild output
    /// answers "what is it printing" but not "how far along is it" — and on a
    /// five-minute archive the second question is the one being asked.
    enum Stage: Int, CaseIterable, Identifiable, Sendable {
        case account, certificate, profiles, archive, export, validate, upload

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .account: "Resolving account"
            case .certificate: "Signing certificate"
            case .profiles: "Provisioning profiles"
            case .archive: "Archiving"
            case .export: "Exporting"
            case .validate: "Validating"
            case .upload: "Uploading"
            }
        }

        var symbol: String {
            switch self {
            case .account: "person.badge.key"
            case .certificate: "checkmark.seal"
            case .profiles: "doc.badge.gearshape"
            case .archive: "shippingbox"
            case .export: "square.and.arrow.down"
            case .validate: "checklist"
            case .upload: "icloud.and.arrow.up"
            }
        }

        /// Roughly how long each step takes, so the detail line can set
        /// expectations rather than leaving a silent minute looking like a hang.
        var hint: String {
            switch self {
            case .account: "Reading the team from your API key"
            case .certificate: "Requesting a certificate for this run"
            case .profiles: "Creating App Store profiles"
            case .archive: "Compiling — this is the slow part"
            case .export: "Re-signing for distribution"
            case .validate: "Checking before anything is sent"
            case .upload: "Transferring to App Store Connect"
            }
        }

        static func steps(upload: Bool) -> [Stage] {
            upload ? allCases : [.account, .certificate, .profiles, .archive, .export]
        }
    }

    let input: Input
    let log: @Sendable (String) -> Void
    /// Called as each stage begins.
    var onStage: @Sendable (Stage) -> Void = { _ in }
    /// Called once, with the path of a newly created signing identity, so the
    /// caller can remember it. Without this the tool creates the file, prints
    /// where it went, and then still shows "Not chosen" — leaving the one
    /// step that makes certificates reusable as a manual chore.
    var onIdentityCreated: @Sendable (String) -> Void = { _ in }

    /// Passphrase on the identity file.
    ///
    /// Fixed and not a secret: macOS `security import` rejects an
    /// empty-password PKCS#12 outright — "MAC verification failed" — so one is
    /// required whether or not it protects anything. It does not: anyone
    /// holding the .p12 can sign with it regardless, exactly as with the .p8.
    /// Guard the file, not this string.
    static let identityPassphrase = "mailboxship"

    private var work: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MailBoxShip", isDirectory: true)
    }

    // MARK: - Entry points

    /// The reusable result of `prepare` — the account-side setup a build needs.
    private struct BuildContext {
        let client: ASCClient
        let team: String
        let certificate: ASCClient.Certificate
        /// The Mac installer identity that signs the `.pkg`, present only on a
        /// macOS run.
        let installerCertificate: ASCClient.Certificate?
        let profiles: [String: String]
    }

    /// Build a signed .ipa and return its path.
    func buildIPA() async throws -> String {
        let keychain = EphemeralKeychain()
        // Runs on every exit path. A failed build must not leave a keychain
        // holding someone else's certificate on this machine.
        defer { Task { await keychain.destroy(log: log) } }

        let context = try await prepare(keychain: keychain)
        return try await assemble(context, buildNumberOverride: nil)
    }

    /// Team, signing certificate and provisioning profiles — the account work a
    /// build depends on.
    ///
    /// Split out from the archive so a rebuild (to land on a build number App
    /// Store Connect will accept, say) reuses all of it rather than asking Apple
    /// for a second certificate and tripping the per-account limit.
    private func prepare(keychain: EphemeralKeychain) async throws -> BuildContext {
        let client = ASCClient(
            keyID: input.keyID, issuerID: input.issuerID,
            privateKeyPath: input.keyPath, proxyDictionary: input.proxyDictionary,
        )
        if input.proxyDictionary != nil {
            // Redacted deliberately: this line ends up in a log the user may
            // paste somewhere.
            log("  Proxy: \(input.proxyDescription)\n")
        }

        onStage(.account)
        try await preflight()

        log("→ Resolving team from the API key…\n")
        let team = try await client.teamID()
        log("  Team: \(team)\n")

        try await keychain.create(log: log)

        let certificate = try await prepareCertificate(
            client: client, keychain: keychain, team: team)

        // A Mac App Store package is signed by a second, installer identity —
        // the app inside is signed by the Apple Distribution certificate above,
        // exactly as on iOS.
        let installerCertificate = input.platform.needsInstallerCertificate
            ? try await prepareInstallerCertificate(client: client, keychain: keychain, team: team)
            : nil

        let profiles = try await prepareProfiles(client: client, team: team, certificate: certificate)

        return BuildContext(
            client: client, team: team, certificate: certificate,
            installerCertificate: installerCertificate, profiles: profiles)
    }

    /// Archive and export a signed .ipa. Repeatable with a different build
    /// number without redoing the account setup in `prepare`.
    private func assemble(
        _ context: BuildContext, buildNumberOverride: String?,
    ) async throws -> String {
        try prepareWorkspace()
        try await archive(team: context.team, buildNumberOverride: buildNumberOverride)
        // Stamp before signing: the stamp rewrites Info.plist, which would
        // invalidate a signature already sealed over it.
        stampVersion(inArchiveAt: archivePath,
                     buildNumber: buildNumberOverride ?? input.buildNumber)
        await embedEntitlements(inArchiveAt: archivePath, team: context.team)

        // The archive is the first place a companion watch app becomes visible,
        // so top up the profile map from what was actually built before signing.
        let complete = try await coverEmbeddedProfiles(
            prepared: context.profiles, client: context.client,
            team: context.team, certificate: context.certificate)

        return try await export(profiles: complete, team: context.team)
    }

    /// Build, validate and upload — bumping the build number and rebuilding on
    /// its own if App Store Connect reports the number as already used.
    func shipToAppStore() async throws {
        guard input.configuration == .release else {
            throw ShipError("Only a Release build can be uploaded to App Store Connect.")
        }
        // altool finds the API key by name, so `validate`/`upload` hand it the
        // exact path with `--p8-file-path` — but the file has to be there.
        guard FileManager.default.fileExists(atPath: input.keyPath) else {
            throw ShipError("Couldn't find the API key file at \(input.keyPath). "
                + "Choose the .p8 again for this profile and try once more.")
        }

        let keychain = EphemeralKeychain()
        defer { Task { await keychain.destroy(log: log) } }
        let context = try await prepare(keychain: keychain)

        // Ask App Store Connect what it already holds *before* archiving, and
        // start above it. A clash found at validation has already cost a full
        // build — and an explicitly configured number is exactly the case that
        // needs checking, since it stays whatever it was until someone edits it,
        // so it clashes on every ship after the first.
        var buildOverride: String?
        if let highest = await highestBuildNumber(client: context.client) {
            let free = String(highest + 1)
            if input.buildNumber.isEmpty {
                buildOverride = free
                log("→ App Store Connect already holds build \(highest); building \(free).\n")
            } else if let requested = Int(input.buildNumber), requested <= highest {
                buildOverride = free
                log("→ Build \(input.buildNumber) is already used on App Store Connect; "
                    + "building \(free) instead.\n")
            }
        }

        var rebuilds = 0
        let maxRebuilds = 5
        while true {
            let ipa = try await assemble(context, buildNumberOverride: buildOverride)

            onStage(.validate)
            log("\n→ Validating before upload…\n")
            switch await validate(ipa: ipa) {
            case .passed:
                break

            case .buildNumberTaken(let next) where rebuilds < maxRebuilds:
                rebuilds += 1
                buildOverride = String(next)
                log("\n↻ Build number already used on App Store Connect — "
                    + "rebuilding as build \(next) automatically…\n")
                continue

            case .buildNumberTaken(let next):
                throw ShipError("Bumped the build number up to \(next) but App Store Connect "
                    + "kept reporting it as already used. Nothing was uploaded.")

            case .failed(let message):
                throw ShipError(message + " Nothing was uploaded, so no build number was used.")
            }

            onStage(.upload)
            log("\n→ Uploading…\n")
            try await upload(ipa: ipa)
            log("\n✅ Uploaded. Processing in App Store Connect takes 5–15 minutes.\n")
            return
        }
    }

    /// One past the highest build number App Store Connect already has for this
    /// app, or nil when there is nothing to go on — a brand-new app, or build
    /// numbers that are not plain integers — in which case the project's own
    /// number stands and any clash is caught and fixed after the fact.
    private func highestBuildNumber(client: ASCClient) async -> Int? {
        guard !input.bundleID.isEmpty,
              let appID = try? await client.appID(bundleID: input.bundleID),
              let builds = try? await client.builds(appID: appID)
        else { return nil }
        return builds.compactMap { Int($0.version) }.max()
    }

    // MARK: - Preflight

    /// Check the configured identifiers against the ones the project actually
    /// builds, before anything is created on the account.
    ///
    /// Nothing downstream catches a mismatch. Export re-signs whatever the
    /// archive holds, and when the profile map has no entry for the app's real
    /// bundle id `xcodebuild` does not object — it signs with the certificate
    /// alone, omits `embedded.mobileprovision`, and exits zero. The first
    /// complaint then arrives from Apple minutes later as "Missing Provisioning
    /// Profile (90174)", by which point App IDs and profiles have been created
    /// on the account for an app that was never being built.
    ///
    /// The identifiers are stored per app profile while the project path is
    /// editable, so the two drift apart simply by pointing an existing profile
    /// at a different project.
    private func preflight() async throws {
        log("→ Checking the project against this app…\n")
        let info = await ProjectInspector.inspect(
            projectPath: input.projectPath, scheme: input.scheme)

        // An unreadable project is not evidence of a mismatch. Let the archive
        // report the real problem rather than blocking on a guess.
        guard !info.bundleID.isEmpty else {
            log("  Could not read the project's identifiers; continuing\n")
            return
        }

        guard info.bundleID == input.bundleID else {
            throw ShipError(
                "Scheme \(input.scheme) builds \(info.bundleID), but Bundle ID is set to "
                + "\(input.bundleID). Nothing was created on your account. Change Bundle ID "
                + "to \(info.bundleID), or choose the project that builds \(input.bundleID).")
        }

        let unknown = input.extensionBundleIDs.filter { !info.extensionBundleIDs.contains($0) }
        guard unknown.isEmpty else {
            let embeds = info.extensionBundleIDs.isEmpty
                ? "this scheme embeds none"
                : "it embeds \(info.extensionBundleIDs.joined(separator: ", "))"
            throw ShipError(
                "\(unknown.joined(separator: ", ")) \(unknown.count == 1 ? "is" : "are") listed "
                + "under Extensions, but \(embeds). Correct the field or clear it.")
        }

        var confirmed = "  \(info.bundleID)"
        if !info.extensionBundleIDs.isEmpty {
            confirmed += " + " + info.extensionBundleIDs.joined(separator: ", ")
        }
        log(confirmed + " ✓\n")
    }

    // MARK: - Signing assets

    /// Obtain a signing identity, reusing the account's existing one.
    ///
    /// A certificate belongs to the *account*, not to an app: one distribution
    /// certificate signs every app on the team. Creating a fresh one per build
    /// — which this used to do, because the private key died with the
    /// temporary keychain — burns through Apple's cap of two within a couple
    /// of runs and then forces a revocation every time. For anyone shipping
    /// several apps repeatedly that is unusable.
    ///
    /// So the identity is kept: the PKCS#12 (certificate plus private key) is
    /// stored in the macOS Keychain, keyed by team and type, and imported into
    /// the run's temporary keychain each time. The login keychain still never
    /// gains a signing identity, and the secret is protected by the Keychain
    /// rather than left on disk — but the certificate itself is created once
    /// and then reused indefinitely.
    private func prepareCertificate(
        client: ASCClient, keychain: EphemeralKeychain, team: String,
    ) async throws -> ASCClient.Certificate {
        let type = input.configuration.certificateType
        onStage(.certificate)
        log("→ Preparing \(type.lowercased()) certificate…\n")

        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let scratchP12 = work.appendingPathComponent("identity.p12").path

        // Reuse the identity file if it still matches a live certificate.
        //
        // A certificate belongs to the account, not to an app — one signs every
        // app on the team. Creating a fresh one per build burns Apple's cap of
        // two within a couple of runs and then forces a revocation every time,
        // which is unusable for several apps built repeatedly. The identity is
        // checked against the account rather than trusted, because one revoked
        // elsewhere would import fine and then fail at signing.
        if !input.identityPath.isEmpty,
           FileManager.default.fileExists(atPath: input.identityPath) {
            let live = (try? await client.certificates(type: type)) ?? []
            let serial = await Self.serial(ofP12: input.identityPath)

            // Compared with leading zeros stripped. OpenSSL prints a serial
            // with them, Apple's API returns it without — so an exact string
            // match always fails, the identity looks stale, and a fresh
            // certificate is minted on every single run. That silently undoes
            // the reuse this whole path exists for.
            if !serial.isEmpty,
               let match = live.first(where: {
                   Self.normalisedSerial($0.serialNumber) == Self.normalisedSerial(serial)
               }) {
                try await keychain.importIdentity(
                    p12Path: input.identityPath, p12Password: Self.identityPassphrase)
                log("  Reusing identity from \((input.identityPath as NSString).lastPathComponent)\n")
                return match
            }
            log("  That identity is no longer valid on the account; requesting a new one\n")
        }

        let keyPath = work.appendingPathComponent("signing.key").path
        let csrPath = work.appendingPathComponent("signing.csr").path

        // The private half never leaves this machine — Apple only sees the
        // CSR's public half.
        _ = await Shell.run("/usr/bin/openssl", ["genrsa", "-out", keyPath, "2048"])
        _ = await Shell.run("/usr/bin/openssl", [
            "req", "-new", "-key", keyPath, "-out", csrPath,
            "-subj", "/CN=MailBoxShip/O=\(team)/C=US",
        ])

        guard let csr = try? String(contentsOfFile: csrPath, encoding: .utf8) else {
            throw ShipError("Could not generate a certificate signing request")
        }
        let stripped = csr
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE REQUEST-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE REQUEST-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()

        let certificate = try await issueCertificate(client: client, type: type, csr: stripped)
        log("  Issued: \(certificate.displayName)\n")

        try await installIdentity(certificate: certificate, privateKeyPath: keyPath)
        try await keychain.importIdentity(
            p12Path: scratchP12, p12Password: Self.identityPassphrase)

        // Keep it beside the API key, so the next build — and every other app
        // on this account — reuses it instead of asking Apple for another.
        let destination = Self.identityDestination(
            near: input.keyPath, team: team, type: type)
        try? FileManager.default.removeItem(atPath: destination)
        try? FileManager.default.copyItem(atPath: scratchP12, toPath: destination)
        log("  Saved identity → \(destination)\n")
        onIdentityCreated(destination)

        return certificate
    }

    /// Serials differ in presentation between OpenSSL and Apple; compare on a
    /// canonical form rather than the printed one.
    private static func normalisedSerial(_ raw: String) -> String {
        let trimmed = raw.uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "0" })
        return String(trimmed)
    }

    /// Serial of the certificate inside a .p12, used to check it is still live.
    private static func serial(ofP12 path: String) async -> String {
        let pem = await Shell.run("/usr/bin/openssl", [
            "pkcs12", "-in", path, "-clcerts", "-nokeys",
            "-passin", "pass:\(identityPassphrase)", "-legacy",
        ])
        // -legacy is unavailable on LibreSSL; fall back to a plain read.
        let source = pem.succeeded ? pem.output : (await Shell.run("/usr/bin/openssl", [
            "pkcs12", "-in", path, "-clcerts", "-nokeys",
            "-passin", "pass:\(identityPassphrase)",
        ])).output

        guard let begin = source.range(of: "-----BEGIN CERTIFICATE-----") else { return "" }
        let certPEM = String(source[begin.lowerBound...])

        let tmp = NSTemporaryDirectory() + "/mbs-serial.pem"
        try? certPEM.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let out = await Shell.run("/usr/bin/openssl", [
            "x509", "-in", tmp, "-noout", "-serial",
        ])
        return out.output
            .replacingOccurrences(of: "serial=", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    private static func identityDestination(
        near keyPath: String, team: String, type: String,
    ) -> String {
        let directory = keyPath.isEmpty
            ? NSHomeDirectory()
            : (keyPath as NSString).deletingLastPathComponent
        return (directory as NSString)
            .appendingPathComponent("Identity_\(team)_\(type).p12")
    }

    private func issueCertificate(
        client: ASCClient, type: String, csr: String,
    ) async throws -> ASCClient.Certificate {
        // Revoke-and-retry in a loop, not once.
        //
        // Apple refuses at the cap and says only "you already have a current
        // certificate" — it does not say how many over you are. An account
        // sitting two or three above the limit therefore needs several
        // revocations, and a single retry just fails again with the identical
        // message, which reads like the replacement setting did nothing.
        let maxRevocations = 5
        var revoked = 0

        while true {
            do {
                return try await client.createCertificate(type: type, csr: csr)
            } catch let error as ShipError where error.message.contains("409") {
                let existing = (try? await client.certificates(type: type)) ?? []

                guard input.allowCertificateReplacement else {
                    let names = existing
                        .map { "      • \($0.displayName) (expires \($0.expirationDate.prefix(10)))" }
                        .joined(separator: "\n")
                    throw ShipError("""
                        Apple refused a new \(type.lowercased()) certificate — this account is at its limit.

                        It already holds \(existing.count):
                        \(names)

                        This tool cannot reuse those: their private keys live on the machines that \
                        created them, not this one.

                        Either revoke one at developer.apple.com → Certificates, or turn on \
                        "Replace oldest certificate if at limit" and run again.
                        """)
                }

                guard revoked < maxRevocations else {
                    throw ShipError(
                        "Revoked \(revoked) \(type.lowercased()) certificate(s) and Apple still "
                        + "refuses a new one. Check developer.apple.com → Certificates — something "
                        + "else is holding the slot."
                    )
                }
                guard let oldest = existing.min(by: { $0.expirationDate < $1.expirationDate }) else {
                    throw ShipError(
                        "Apple reported the certificate limit but lists none that can be replaced."
                    )
                }

                if revoked == 0 {
                    log("  ⚠︎ At the limit — \(existing.count) \(type.lowercased()) "
                        + "certificate(s) exist; revoking oldest first\n")
                }
                log("    revoking \(oldest.displayName) (expires \(oldest.expirationDate.prefix(10)))\n")
                try await client.revokeCertificate(id: oldest.id)
                revoked += 1
            }
        }
    }

    /// Obtain and install the Mac Installer Distribution identity that signs a
    /// Mac App Store `.pkg`, reusing the saved one while it still matches a live
    /// certificate.
    ///
    /// A second identity, of a different type, needed only on macOS: the app is
    /// signed by the Apple Distribution certificate exactly as on iOS, but the
    /// installer package Apple requires for the Mac App Store is signed by this
    /// one. Kept beside the API key like the app identity, so Apple's
    /// two-per-type cap is not burned on every run.
    private func prepareInstallerCertificate(
        client: ASCClient, keychain: EphemeralKeychain, team: String,
    ) async throws -> ASCClient.Certificate {
        let type = "MAC_INSTALLER_DISTRIBUTION"
        log("→ Preparing Mac installer certificate…\n")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        // Reuse the saved installer identity if it still matches a live cert,
        // checked against the account rather than trusted — one revoked
        // elsewhere would import fine and then fail at signing.
        let destination = Self.identityDestination(near: input.keyPath, team: team, type: type)
        if FileManager.default.fileExists(atPath: destination) {
            let live = (try? await client.certificates(type: type)) ?? []
            let serial = await Self.serial(ofP12: destination)
            if !serial.isEmpty,
               let match = live.first(where: {
                   Self.normalisedSerial($0.serialNumber) == Self.normalisedSerial(serial)
               }) {
                try await keychain.importIdentity(
                    p12Path: destination, p12Password: Self.identityPassphrase)
                log("  Reusing installer identity from \((destination as NSString).lastPathComponent)\n")
                return match
            }
            log("  Saved installer identity is no longer valid on the account; requesting a new one\n")
        }

        let keyPath = work.appendingPathComponent("installer.key").path
        let csrPath = work.appendingPathComponent("installer.csr").path
        _ = await Shell.run("/usr/bin/openssl", ["genrsa", "-out", keyPath, "2048"])
        _ = await Shell.run("/usr/bin/openssl", [
            "req", "-new", "-key", keyPath, "-out", csrPath,
            "-subj", "/CN=MailBoxShip Installer/O=\(team)/C=US",
        ])
        guard let csr = try? String(contentsOfFile: csrPath, encoding: .utf8) else {
            throw ShipError("Could not generate an installer certificate request")
        }
        let stripped = csr
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE REQUEST-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE REQUEST-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()

        let certificate = try await issueCertificate(client: client, type: type, csr: stripped)
        log("  Issued: \(certificate.displayName)\n")

        // installIdentity writes the identity to work/identity.p12; import that,
        // then keep a copy for reuse.
        try await installIdentity(certificate: certificate, privateKeyPath: keyPath)
        let scratchP12 = work.appendingPathComponent("identity.p12").path
        try await keychain.importIdentity(p12Path: scratchP12, p12Password: Self.identityPassphrase)

        try? FileManager.default.removeItem(atPath: destination)
        try? FileManager.default.copyItem(atPath: scratchP12, toPath: destination)
        log("  Saved installer identity → \(destination)\n")
        return certificate
    }

    private func installIdentity(
        certificate: ASCClient.Certificate, privateKeyPath: String,
    ) async throws {
        guard let der = Data(base64Encoded: certificate.content) else {
            throw ShipError("Apple returned a certificate that could not be decoded")
        }
        let cerPath = work.appendingPathComponent("signing.cer")
        try der.write(to: cerPath)

        let pemPath = work.appendingPathComponent("signing.pem").path
        let p12Path = work.appendingPathComponent("identity.p12").path

        // /usr/bin/openssl explicitly, not whatever is first on PATH.
        // That one is LibreSSL, which writes a PKCS#12 the macOS keychain
        // accepts; Homebrew's OpenSSL 3 defaults to AES-256/SHA-256 and
        // `security import` rejects the result as "MAC verification failed".
        let toPem = await Shell.run("/usr/bin/openssl", [
            "x509", "-inform", "DER", "-in", cerPath.path, "-out", pemPath,
        ])
        guard toPem.succeeded else {
            throw ShipError("Could not convert the certificate: \(toPem.output)")
        }

        let toP12 = await Shell.run("/usr/bin/openssl", [
            "pkcs12", "-export", "-inkey", privateKeyPath, "-in", pemPath,
            "-out", p12Path, "-passout", "pass:\(Self.identityPassphrase)",
        ])
        guard toP12.succeeded else {
            throw ShipError("Could not package the signing identity: \(toP12.output)")
        }
    }

    private var profileDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/MobileDevice/Provisioning Profiles", isDirectory: true)
    }

    private func prepareProfiles(
        client: ASCClient, team: String, certificate: ASCClient.Certificate,
    ) async throws -> [String: String] {
        onStage(.profiles)
        log("→ Preparing provisioning profiles…\n")

        let profileDir = profileDirectory
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        var mapping: [String: String] = [:]
        for identifier in [input.bundleID] + input.extensionBundleIDs {
            mapping[identifier] = try await prepareProfile(
                for: identifier, client: client, team: team, certificate: certificate,
                profileDir: profileDir,
                entitlementsPath: input.entitlementsPath(for: identifier))
        }
        return mapping
    }

    /// Create an App ID (if needed) and a fresh provisioning profile for one
    /// bundle id, and drop the profile where `xcodebuild` looks for it.
    private func prepareProfile(
        for identifier: String, client: ASCClient, team: String,
        certificate: ASCClient.Certificate, profileDir: URL, entitlementsPath: String,
    ) async throws -> String {
        let resource = try await client.bundleID(
            identifier: identifier,
            name: identifier.replacingOccurrences(of: ".", with: " "),
            seedID: team,
            platform: input.platform.bundleIDPlatform,
        )

        // Turn on whatever this target's entitlements imply, before the profile
        // is issued — a profile inherits capabilities at creation, so enabling
        // one afterwards has no effect on it.
        let keys = Capabilities.entitlementKeys(atPath: entitlementsPath)
        let (enable, manual) = Capabilities.resolve(entitlementKeys: keys)

        for capability in enable {
            await client.enableCapability(capability, bundleIDResource: resource)
        }
        if !enable.isEmpty {
            log("    capabilities: \(enable.joined(separator: ", "))\n")
        }
        for note in manual {
            // Cannot be fixed from here, and silently omitting it would produce
            // an archive failure that names the profile instead.
            log("    ⚠︎ \(note)\n")
        }

        // Timestamped: profile names are unique per team, and reusing one from a
        // previous run collides.
        let name = "Ship \(identifier) \(Int(Date().timeIntervalSince1970))"
        let profile = try await client.createProfile(
            name: name,
            type: input.platform.profileType(input.configuration),
            bundleIDResource: resource,
            certificateID: certificate.id,
        )

        if let data = Data(base64Encoded: profile.content) {
            try data.write(to: profileDir.appendingPathComponent("\(profile.uuid).mobileprovision"))
        }
        log("  \(identifier) → \(profile.uuid)\n")
        return profile.name
    }

    /// Ensure every bundle the archive actually embeds has a profile, creating
    /// any that preparation missed.
    ///
    /// `-showBuildSettings` on the app's scheme reports the app and its app
    /// extensions, but not a **companion watch app** — that has its own scheme
    /// and is folded in only at archive time, embedded under `…/Watch/`. So the
    /// profile map built before the archive has no entry for it, export re-signs
    /// it without one, and Apple rejects the upload as 90174. Reading the bundle
    /// ids straight out of the finished archive is the one source that cannot
    /// miss them: whatever is in there is exactly what must be signed.
    private func coverEmbeddedProfiles(
        prepared: [String: String], client: ASCClient, team: String,
        certificate: ASCClient.Certificate,
    ) async throws -> [String: String] {
        let embedded = embeddedBundleIDs(inArchiveAt: archivePath)
        let missing = embedded.filter { prepared[$0] == nil }.sorted()
        guard !missing.isEmpty else { return prepared }

        log("→ Covering embedded targets the scheme did not surface: "
            + "\(missing.joined(separator: ", "))\n")

        // A watch app carries its own entitlements on its own target, so gather
        // them across every scheme — otherwise its App ID is created bare and a
        // capability its code relies on (App Groups, say) is silently dropped.
        let entitlements = await ProjectInspector.entitlementsAcrossSchemes(
            projectPath: input.projectPath)

        let profileDir = profileDirectory
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        var mapping = prepared
        for identifier in missing {
            mapping[identifier] = try await prepareProfile(
                for: identifier, client: client, team: team, certificate: certificate,
                profileDir: profileDir,
                entitlementsPath: entitlements[identifier]
                    ?? input.entitlementsPath(for: identifier))
        }
        return mapping
    }

    /// The Info.plist at the root of every bundle inside the archive's app: the
    /// host, its extensions, an embedded watch app and anything that app embeds
    /// in turn.
    ///
    /// iOS keeps a bundle's Info.plist at its root (`X.app/Info.plist`); macOS
    /// keeps it under `X.app/Contents/Info.plist`. Accept both, but nothing
    /// deeper — a framework's own Info.plist is not a target.
    private func bundleRootInfoPlists(inArchiveAt archive: String) -> [String] {
        let root = (archive as NSString).appendingPathComponent("Products/Applications")
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }

        var paths: [String] = []
        for case let relative as String in walker {
            guard (relative as NSString).lastPathComponent == "Info.plist" else { continue }
            let directory = (relative as NSString).deletingLastPathComponent as NSString
            let container = directory.lastPathComponent
            let parent = (directory.deletingLastPathComponent as NSString).lastPathComponent
            let atBundleRoot = container.hasSuffix(".app") || container.hasSuffix(".appex")
            let atMacBundleRoot = container == "Contents"
                && (parent.hasSuffix(".app") || parent.hasSuffix(".appex"))
            guard atBundleRoot || atMacBundleRoot else { continue }
            paths.append((root as NSString).appendingPathComponent(relative))
        }
        return paths
    }

    /// Every bundle id inside the archive's app, read from each bundle's own
    /// Info.plist, so it reflects what was built, not what was predicted.
    private func embeddedBundleIDs(inArchiveAt archive: String) -> [String] {
        var ids = Set<String>()
        for path in bundleRootInfoPlists(inArchiveAt: archive) {
            if let data = FileManager.default.contents(atPath: path),
               let plist = try? PropertyListSerialization.propertyList(
                   from: data, format: nil) as? [String: Any],
               let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty {
                ids.insert(id)
            }
        }
        return Array(ids)
    }

    /// Embed each bundle's declared entitlements into the archive.
    ///
    /// Entitlements are written *by* codesign, and the archive is deliberately
    /// built unsigned — so nothing the project declares is in it, and
    /// `-exportArchive` then signs from the provisioning profile alone. The
    /// shipped app comes out carrying only `com.apple.application-identifier`
    /// and `com.apple.developer.team-identifier`: App Sandbox, keychain groups,
    /// app groups and the rest are gone. macOS catches that at validation
    /// ("App sandbox not enabled"); iOS does not, and uploads an app that
    /// installs and then fails at runtime wherever a missing entitlement bites.
    ///
    /// Signing ad-hoc here is only a carrier — export re-signs with the real
    /// identity and the per-bundle profiles, and keeps the entitlements it
    /// finds. Archiving ad-hoc instead would be simpler, but Xcode refuses:
    /// a target declaring entitlements demands a provisioning profile at build
    /// time, which is exactly what signing at export exists to avoid.
    private func embedEntitlements(inArchiveAt archive: String, team: String) async {
        // Deepest first: codesign requires nested bundles to be signed before
        // the bundle that contains them.
        let bundles = archivedBundles(inArchiveAt: archive)
            .sorted { $0.bundle.count > $1.bundle.count }

        for (bundle, plistPath) in bundles {
            guard let data = FileManager.default.contents(atPath: plistPath),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, format: nil) as? [String: Any],
                  let identifier = plist["CFBundleIdentifier"] as? String
            else { continue }

            let source = input.entitlementsPath(for: identifier)
            guard !source.isEmpty,
                  let declared = try? String(contentsOfFile: source, encoding: .utf8)
            else { continue }

            // Xcode expands these from the provisioning profile as it signs;
            // codesign does not, and would embed the literal `$(...)` text.
            let expanded = declared
                .replacingOccurrences(of: "$(AppIdentifierPrefix)", with: "\(team).")
                .replacingOccurrences(of: "$(TeamIdentifierPrefix)", with: "\(team).")

            let resolved = work.appendingPathComponent(
                "build/entitlements-\(Self.pathSafe(identifier)).plist")
            guard (try? expanded.write(to: resolved, atomically: true, encoding: .utf8)) != nil
            else { continue }

            let result = await Shell.run("/usr/bin/codesign", [
                "--force", "--sign", "-", "--entitlements", resolved.path, bundle,
            ])
            if result.succeeded {
                log("  Entitlements embedded for \(identifier)\n")
            } else {
                log("  ⚠︎ Could not embed entitlements for \(identifier) — the upload will "
                    + "be missing them.\n\(result.output)\n")
            }
        }
    }

    /// The bundles inside the archive's app, each with its own Info.plist.
    private func archivedBundles(inArchiveAt archive: String) -> [(bundle: String, plist: String)] {
        bundleRootInfoPlists(inArchiveAt: archive).map { plist in
            let directory = (plist as NSString).deletingLastPathComponent
            // macOS nests the plist one deeper, under `X.app/Contents`.
            let isMac = (directory as NSString).lastPathComponent == "Contents"
            return (isMac ? (directory as NSString).deletingLastPathComponent : directory, plist)
        }
    }

    /// Write the version and build number into the archive itself.
    ///
    /// `CURRENT_PROJECT_VERSION` on the command line only reaches the built app
    /// when its Info.plist asks for it — a generated plist, or a literal one
    /// written as `$(CURRENT_PROJECT_VERSION)`. A project that instead hardcodes
    /// `<string>1</string>` ignores the override completely, and nothing says
    /// so: every rebuild ships the same number, App Store Connect rejects each
    /// one as already used, and the automatic bump loops until it gives up
    /// having burned a full build per attempt. Stamping the archive is the one
    /// place that works whatever the project does.
    ///
    /// Safe because the archive is built unsigned and export signs it
    /// afterwards. Extensions are stamped too — Apple rejects an upload whose
    /// extension build number differs from its host app's.
    private func stampVersion(inArchiveAt archive: String, buildNumber: String) {
        guard !buildNumber.isEmpty || !input.marketingVersion.isEmpty else { return }

        for path in bundleRootInfoPlists(inArchiveAt: archive) {
            var format = PropertyListSerialization.PropertyListFormat.xml
            guard let data = FileManager.default.contents(atPath: path),
                  var plist = try? PropertyListSerialization.propertyList(
                      from: data, format: &format) as? [String: Any]
            else { continue }

            if !buildNumber.isEmpty { plist["CFBundleVersion"] = buildNumber }
            if !input.marketingVersion.isEmpty {
                plist["CFBundleShortVersionString"] = input.marketingVersion
            }
            if let updated = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: format, options: 0) {
                try? updated.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: - Build

    private func prepareWorkspace() throws {
        try? FileManager.default.removeItem(at: work.appendingPathComponent("build"))
        try FileManager.default.createDirectory(
            at: work.appendingPathComponent("build"), withIntermediateDirectories: true,
        )
    }

    private var archivePath: String {
        work.appendingPathComponent("build/App.xcarchive").path
    }

    private func archive(team: String, buildNumberOverride: String? = nil) async throws {
        onStage(.archive)
        log("\n→ Archiving (\(input.configuration.rawValue))… this takes a few minutes\n")

        // An override wins over the project's own number; it is how a rebuild
        // lands on a build number App Store Connect will accept.
        let buildNumber = buildNumberOverride ?? input.buildNumber

        var args = ProjectInspector.container(forProjectPath: input.projectPath).arguments + [
            "-scheme", input.scheme,
            "-configuration", input.configuration.rawValue,
            "-destination", input.platform.archiveDestination,
            "-archivePath", archivePath,
            "-derivedDataPath", work.appendingPathComponent("build/DerivedData").path,
            "DEVELOPMENT_TEAM=\(team)",

            // Archive unsigned; sign entirely at export.
            //
            // Most projects use automatic signing, and automatic signing wants
            // an Apple ID account in Xcode. With only an API key it refuses —
            // and it refuses *misleadingly*, reporting "requires a provisioning
            // profile with the Push Notifications feature" even when a correct
            // profile carrying exactly that is already installed, because it
            // never looks at installed profiles at all.
            //
            // Signing at export instead is also the only way to give the app
            // and each extension a *different* profile: build settings passed
            // on the command line apply to every target at once, whereas
            // ExportOptions.plist maps a profile per bundle id.
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGN_IDENTITY=",
            "CODE_SIGN_STYLE=Manual",
        ]
        if !input.marketingVersion.isEmpty { args.append("MARKETING_VERSION=\(input.marketingVersion)") }
        if !buildNumber.isEmpty { args.append("CURRENT_PROJECT_VERSION=\(buildNumber)") }
        args.append("archive")

        let result = await Shell.run("/usr/bin/xcodebuild", args, onOutput: log)
        guard result.succeeded else {
            throw ShipError("Archive failed. The log above has the compiler's own message.")
        }
        log("  Archive succeeded\n")
    }

    private func export(profiles: [String: String], team: String) async throws -> String {
        onStage(.export)
        log("\n→ Exporting signed \(input.platform == .macOS ? "package" : "app")…\n")
        let exportDir = work.appendingPathComponent("build/export")

        var options: [String: Any] = [
            "method": input.configuration.exportMethod,
            "destination": "export",
            "teamID": team,
            // Manual, always. Automatic routes through Xcode's cloud signing,
            // which refuses App Store Connect API keys — the failure reads
            // "Cloud signing permission error" and misleadingly suggests the
            // key lacks permissions it actually has.
            "signingStyle": "manual",
            "signingCertificate": input.configuration.signingCertificate,
            "provisioningProfiles": profiles,
            "manageAppVersionAndBuildNumber": false,
        ]
        if input.configuration == .release { options["uploadSymbols"] = true }
        if input.platform == .macOS {
            // The Mac App Store package is signed by the installer identity;
            // without naming it here, manual export leaves the .pkg unsigned and
            // Apple rejects the upload.
            options["installerSigningCertificate"] = "3rd Party Mac Developer Installer"
        }

        let plistPath = work.appendingPathComponent("build/ExportOptions.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: options, format: .xml, options: 0,
        )
        try data.write(to: plistPath)

        let result = await Shell.run("/usr/bin/xcodebuild", [
            "-exportArchive",
            "-archivePath", archivePath,
            "-exportPath", exportDir.path,
            "-exportOptionsPlist", plistPath.path,
        ], onOutput: log)

        guard result.succeeded else { throw ShipError("Export failed. See the log above.") }

        let contents = try FileManager.default.contentsOfDirectory(atPath: exportDir.path)
        let suffix = input.platform.artifactSuffix
        guard let artifact = contents.first(where: { $0.hasSuffix(suffix) }) else {
            throw ShipError("Export reported success but produced no \(suffix)")
        }
        // Kept before it is judged: a rejected artifact is exactly the one worth
        // opening, and the build directory it would otherwise sit in is deleted
        // at the start of the next run.
        let kept = preserve(ipa: exportDir.appendingPathComponent(artifact).path, exportDir: exportDir)
        log("  \(kept)\n")
        // The provisioning check reads an .ipa's zip layout; a macOS .pkg is a
        // different container that export has already signed, so skip it there
        // rather than fail on a format it cannot read.
        if input.platform == .iOS {
            try await verifyProvisioned(ipa: kept)
        }
        return kept
    }

    /// Where finished .ipa files are kept, outside the build directory.
    ///
    /// `~/Developer` rather than `~/Documents`: writing to Documents raises a
    /// TCC prompt mid-run and leaves the build stranded in a temporary folder
    /// if it is denied. Neither Developer nor Application Support prompts, and
    /// of the two only one is somewhere a person would think to open.
    static var outputRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Developer/MailBoxShip", isDirectory: true)
    }

    /// Copy the signed .ipa somewhere it survives the next run.
    ///
    /// Export writes into the temporary build directory, which `prepareWorkspace`
    /// deletes at the start of every run — so by the time there is any reason to
    /// look at a build (comparing it against the next one, checking what was
    /// actually signed, uploading it by hand) it is already gone. Filed by
    /// scheme and configuration, and named with the version, build and time, so
    /// a folder of them can be read without opening any.
    ///
    /// Failure here is reported and ignored: the .ipa exists and is valid, and
    /// losing a successful build over a copy would be the worse outcome.
    private func preserve(ipa: String, exportDir: URL) -> String {
        let folder = Self.outputRoot
            .appendingPathComponent(Self.pathSafe(input.scheme), isDirectory: true)
            .appendingPathComponent(input.configuration.rawValue, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(fileName(exportDir: exportDir))
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: ipa), to: destination)
            return destination.path
        } catch {
            log("  ⚠︎ Could not keep a copy in \(folder.path): \(error.localizedDescription)\n")
            return ipa
        }
    }

    /// `Craftly-1.0.0-b12-Release-20260802-2219.ipa`.
    private func fileName(exportDir: URL) -> String {
        var version = input.marketingVersion
        var build = input.buildNumber

        // Export's own summary is authoritative. The version fields are
        // optional here, and when they are left blank the numbers come from the
        // project — this is the only place they are reported back.
        if let data = try? Data(
            contentsOf: exportDir.appendingPathComponent("DistributionSummary.plist")),
           let plist = try? PropertyListSerialization.propertyList(
               from: data, format: nil) as? [String: Any],
           let entry = plist.values.compactMap({ ($0 as? [[String: Any]])?.first }).first {
            version = entry["versionNumber"] as? String ?? version
            build = entry["buildNumber"] as? String ?? build
        }

        let stamp = DateFormatter()
        // Fixed locale: a filename built from a non-Gregorian calendar sorts
        // and reads as something else entirely.
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmm"

        var name = Self.pathSafe(input.scheme)
        if !version.isEmpty { name += "-\(version)" }
        if !build.isEmpty { name += "-b\(build)" }
        name += "-\(input.configuration.rawValue)-\(stamp.string(from: Date()))\(input.platform.artifactSuffix)"
        return name
    }

    /// "/" is a path separator, and Finder still shows ":" as one.
    private static func pathSafe(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "App" : cleaned
    }

    /// Confirm every bundle in the .ipa carries a provisioning profile.
    ///
    /// A zero exit from `-exportArchive` is not evidence of a provisioned app:
    /// given a profile map with no entry for a bundle id, it re-signs with the
    /// certificate and simply leaves the profile out. Apple rejects that as
    /// 90174, but only after an upload attempt — reading the zip's table of
    /// contents costs a moment and gives the same answer here.
    private func verifyProvisioned(ipa: String) async throws {
        let listing = await Shell.run("/usr/bin/unzip", ["-Z1", ipa])
        // Unreadable listing means the check is unavailable, not that the app
        // is unsigned; leave the verdict to validation.
        guard listing.succeeded else { return }

        let entries = Set(listing.output.split(separator: "\n").map(String.init))

        // Every path component ending in .app or .appex is a bundle that needs
        // its own profile — the host app and each extension it embeds.
        var bundles = Set<String>()
        for entry in entries {
            var prefix = ""
            for component in entry.split(separator: "/").dropLast() {
                prefix += component + "/"
                if component.hasSuffix(".app") || component.hasSuffix(".appex") {
                    bundles.insert(prefix)
                }
            }
        }

        let missing = bundles
            .filter { !entries.contains($0 + "embedded.mobileprovision") }
            .map { ($0 as NSString).lastPathComponent }
            .sorted()

        guard missing.isEmpty else {
            throw ShipError(
                "\(missing.joined(separator: ", ")) came out of export without a provisioning "
                + "profile, which Apple rejects as 90174. The profiles prepared for this run "
                + "do not cover the bundle ids these targets actually build.")
        }
    }

    // MARK: - Delivery

    /// What validation decided, in a form the ship loop can act on.
    private enum Validation {
        case passed
        /// App Store Connect already has this build number; rebuild as `next`.
        case buildNumberTaken(next: Int)
        /// Something else, already in plain language.
        case failed(message: String)
    }

    private func validate(ipa: String) async -> Validation {
        let result = await Shell.run("/usr/bin/xcrun", [
            "altool", "--validate-app", "-f", ipa, "-t", input.platform.altoolType,
            "--apiKey", input.keyID, "--apiIssuer", input.issuerID,
            "--p8-file-path", input.keyPath,
        ], environment: input.proxyEnvironment, onOutput: log)

        if result.succeeded { return .passed }
        if let previous = Self.usedBuildNumber(in: result.output) {
            return .buildNumberTaken(next: previous + 1)
        }
        return .failed(message: Self.humanize(Self.reason(fromAltool: result.output) ?? "Validation failed."))
    }

    /// The build number App Store Connect reports as already used, when that is
    /// why altool refused the archive.
    ///
    /// Apple phrases it two ways depending on the path — a plain "must be higher
    /// than the previously uploaded version: '1'", or a redelivery that names
    /// `previousBundleVersion` — so both markers are checked.
    private static func usedBuildNumber(in output: String) -> Int? {
        let markers = [
            "previously uploaded version: '",
            "previousBundleVersion : ",
            "previousBundleVersion: ",
        ]
        for marker in markers {
            guard let range = output.range(of: marker) else { continue }
            let digits = output[range.upperBound...].prefix { $0.isNumber }
            if let value = Int(digits) { return value }
        }
        return nil
    }

    /// App Store Connect's delivery errors in plain language.
    ///
    /// altool passes Apple's raw wording straight through — accurate, but
    /// written for a machine ("-19232", "ENTITY_ERROR.ATTRIBUTE…"). Recognise
    /// the common ones and say what happened and what to do about it. Anything
    /// unrecognised falls through unchanged: a specific Apple sentence still
    /// beats a vague paraphrase.
    private static func humanize(_ reason: String) -> String {
        let lower = reason.lowercased()
        func has(_ needle: String) -> Bool { lower.contains(needle) }

        if has("-19232") || (has("bundle version") && (has("higher") || has("already been used"))) {
            return "That build number is already on App Store Connect — every upload needs a higher one."
        }
        if has("redundant binary") || (has("already been used") && has("version")) {
            return "App Store Connect already has this exact version and build number. Raise the build number and try again."
        }
        if has("failed to load authkey") || has("(-43)") {
            return "The App Store Connect API key (.p8) couldn't be found. Choose the key again."
        }
        if has("not authorized") || has("authentication credentials") || has("401") || has("forbidden") {
            return "App Store Connect rejected the API key. Check the key, its Issuer ID, and that its role is App Manager."
        }
        if has("no suitable application") || has("no app ") || (has("cannot find") && has("app")) {
            return "There's no app record for this bundle id in App Store Connect yet. Create the app there first (My Apps → +)."
        }
        if has("90174") || (has("provisioning profile") && has("without")) {
            return "A target was signed without a provisioning profile."
        }
        if has("invalid code sign") || has("code signing") {
            return "Code signing was rejected — the certificate or a provisioning profile doesn't match what was built."
        }
        if has("asset validation") && has("icon") {
            return "An app icon is missing or the wrong size. Fix the icons in the asset catalog and rebuild."
        }
        return reason
    }

    /// The one line worth repeating out of altool's output.
    ///
    /// altool exits non-zero having already printed the cause, but that cause
    /// sits inside hundreds of lines of transfer chatter — so "Validation
    /// failed" on its own sends the reader back to search a log for the
    /// sentence the tool has already read. Apple's wording names the problem
    /// and its numeric code, which is also what makes it searchable.
    private static func reason(fromAltool output: String) -> String? {
        for line in output.split(separator: "\n") {
            var text = String(line)
            guard let marker = text.range(of: "ERROR: ") ?? text.range(of: "*** Error: ")
            else { continue }
            text = String(text[marker.upperBound...])

            // "[altool.1037A6DD0] " — a subsystem id, never useful.
            if text.hasPrefix("["), let close = text.range(of: "] ") {
                text = String(text[close.upperBound...])
            }
            // The exit status only repeats what the caller already knows.
            if text.hasPrefix("ExitFailure") { continue }
            // Apple appends the raw server body after the sentence; the
            // sentence is the part a person can act on.
            if let tail = text.range(of: "The server") { text = String(text[..<tail.lowerBound]) }

            text = text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return String(text.prefix(220)) }
        }
        return nil
    }

    private func upload(ipa: String) async throws {
        let result = await Shell.run("/usr/bin/xcrun", [
            "altool", "--upload-app", "-f", ipa, "-t", input.platform.altoolType,
            "--apiKey", input.keyID, "--apiIssuer", input.issuerID,
            "--p8-file-path", input.keyPath,
        ], environment: input.proxyEnvironment, onOutput: log)
        guard result.succeeded else {
            throw ShipError(Self.humanize(
                Self.reason(fromAltool: result.output) ?? "Upload failed. See the log above."))
        }
    }
}

extension Pipeline.Input {
    /// Assemble the pipeline input straight from a saved profile.
    ///
    /// Both the simple and the advanced screen start a run the same way, so the
    /// mapping from a `ShipProfile` to what the pipeline consumes lives here
    /// once — otherwise the two paths drift and one of them quietly ships with,
    /// say, the proxy environment left off.
    @MainActor
    init(
        profile p: ShipProfile,
        configuration: Pipeline.Configuration,
        platform: ShipPlatform = .iOS,
        entitlementsByBundleID: [String: String],
    ) {
        self.init(
            projectPath: p.projectPath,
            scheme: p.scheme,
            configuration: configuration,
            platform: platform,
            bundleID: p.bundleID,
            extensionBundleIDs: p.extensionBundleIDs,
            keyPath: p.keyPath,
            keyID: p.keyID,
            issuerID: p.issuerID,
            marketingVersion: p.marketingVersion,
            buildNumber: p.buildNumber,
            allowCertificateReplacement: p.allowCertificateReplacement,
            entitlementsByBundleID: entitlementsByBundleID,
            proxyDictionary: p.proxy.sessionProxyDictionary,
            proxyEnvironment: p.proxy.toolEnvironment,
            proxyDescription: p.proxy.redactedDescription,
            identityPath: p.identityPath,
        )
    }
}

// MARK: - Platform-specific shipping values

extension ShipPlatform {
    /// The `-destination` an archive is built for.
    var archiveDestination: String {
        switch self {
        case .iOS: "generic/platform=iOS"
        case .macOS: "generic/platform=macOS"
        }
    }

    /// `altool`'s `-t` on validate and upload.
    var altoolType: String {
        switch self {
        case .iOS: "ios"
        case .macOS: "macos"
        }
    }

    /// What `-exportArchive` produces for the App Store: an `.ipa` on iOS, a
    /// signed installer package on macOS.
    var artifactSuffix: String {
        switch self {
        case .iOS: ".ipa"
        case .macOS: ".pkg"
        }
    }

    /// App ID platform on the Developer portal.
    var bundleIDPlatform: String {
        switch self {
        case .iOS: "IOS"
        case .macOS: "MAC_OS"
        }
    }

    /// A Mac App Store package is signed by an installer certificate the app
    /// build never touches; iOS has no equivalent.
    var needsInstallerCertificate: Bool { self == .macOS }

    /// The App Store provisioning profile type for a configuration.
    func profileType(_ configuration: Pipeline.Configuration) -> String {
        switch (self, configuration) {
        case (.iOS, .release): "IOS_APP_STORE"
        case (.iOS, .debug): "IOS_APP_DEVELOPMENT"
        case (.macOS, .release): "MAC_APP_STORE"
        case (.macOS, .debug): "MAC_APP_DEVELOPMENT"
        }
    }
}
