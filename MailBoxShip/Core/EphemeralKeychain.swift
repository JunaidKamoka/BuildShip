import Foundation

/// A keychain that exists only for the duration of one build.
///
/// This is the mechanism behind "nothing local". The signing identity has to
/// live in *a* keychain for `codesign` to find it, but it must not live in the
/// user's login keychain — that would leave another account's distribution
/// certificate installed on this machine indefinitely, which is precisely the
/// entanglement this tool exists to avoid.
///
/// So: a throwaway keychain per run, added to the search list rather than made
/// default (making it default would change signing behaviour for every other
/// tool while it exists), and deleted afterwards even if the build fails.
actor EphemeralKeychain {

    private let name: String
    private let password: String
    private var created = false

    init() {
        // Unique per run so two concurrent builds cannot collide, and so a
        // crashed previous run leaves nothing this one might reuse by accident.
        name = "mailboxship-\(UUID().uuidString.prefix(8)).keychain"
        password = UUID().uuidString
    }

    var path: String { name }

    func create(log: @Sendable (String) -> Void) async throws {
        _ = await Shell.run("/usr/bin/security", ["delete-keychain", name])

        let create = await Shell.run("/usr/bin/security", ["create-keychain", "-p", password, name])
        guard create.succeeded else {
            throw ShipError("Could not create a temporary keychain: \(create.output)")
        }
        created = true

        _ = await Shell.run("/usr/bin/security", ["unlock-keychain", "-p", password, name])
        // No auto-lock timeout: a long archive must not have the keychain lock
        // out from under it half way through signing.
        _ = await Shell.run("/usr/bin/security", ["set-keychain-settings", name])

        // Append to the user's search list. Deliberately not `default-keychain`,
        // which would redirect every other tool's lookups for as long as it exists.
        let existing = await Shell.run("/usr/bin/security", ["list-keychains", "-d", "user"])
        let others = existing.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { !$0.isEmpty && !$0.contains("mailboxship-") }

        _ = await Shell.run(
            "/usr/bin/security", ["list-keychains", "-d", "user", "-s", name] + others,
        )
        log("Created temporary keychain \(name)\n")
    }

    /// Import a PKCS#12 holding the distribution certificate and its key.
    func importIdentity(p12Path: String, p12Password: String) async throws {
        _ = await Shell.run("/usr/bin/security", ["unlock-keychain", "-p", password, name])

        let result = await Shell.run("/usr/bin/security", [
            "import", p12Path,
            "-k", name,
            "-P", p12Password,
            "-T", "/usr/bin/codesign",
            "-T", "/usr/bin/security",
            "-A",
        ])
        guard result.succeeded else {
            let hint = result.output.contains("MAC verification failed")
                ? " That usually means the .p12 has a different passphrase — this tool can "
                  + "only reuse an identity it created itself. Clear the Signing identity "
                  + "field and let it make a new one."
                : ""
            throw ShipError("Could not import the signing identity.\(hint) \(result.output)")
        }

        // Without this, codesign triggers an interactive "allow access?" prompt
        // that no one is present to answer, and the build hangs indefinitely.
        _ = await Shell.run("/usr/bin/security", [
            "set-key-partition-list",
            "-S", "apple-tool:,apple:,codesign:",
            "-s", "-k", password, name,
        ])
    }

    /// Remove the keychain and drop it from the search list.
    ///
    /// Safe to call twice, and called from a `defer` so a thrown error mid-build
    /// still cleans up. Leaving these behind would accumulate one stale keychain
    /// per failed build.
    func destroy(log: (@Sendable (String) -> Void)? = nil) async {
        guard created else { return }
        created = false

        let existing = await Shell.run("/usr/bin/security", ["list-keychains", "-d", "user"])
        let others = existing.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { !$0.isEmpty && !$0.contains("mailboxship-") }
        _ = await Shell.run("/usr/bin/security", ["list-keychains", "-d", "user", "-s"] + others)

        _ = await Shell.run("/usr/bin/security", ["delete-keychain", name])
        log?("Removed temporary keychain \(name)\n")
    }
}
