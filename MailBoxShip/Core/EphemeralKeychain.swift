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
///
/// It sits on the search list only while the run is actually signing — see
/// `attach`. Several apps can build at once, and two of them on one account
/// hold the *same* identity; with both keychains listed, `codesign` and export
/// are handed two copies of one certificate and may take either. Importing and
/// reading the identity name the keychain explicitly, so nothing else needs it
/// listed.
actor EphemeralKeychain {

    private let name: String
    private let password: String
    private var created = false
    private var attached = false

    /// Serialises every read-modify-write of the user's search list across
    /// runs. Without it two runs both read the list, both write it back, and
    /// the second write drops whatever the first one added.
    private static let searchList = AsyncLock()

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
        log("Created temporary keychain \(name)\n")
    }

    /// Put this keychain on the user's search list, so `codesign` and
    /// `xcodebuild -exportArchive` — which take an identity by hash or by name,
    /// never by keychain — can find it.
    ///
    /// Callers hold the pipeline's signing lock for as long as this keychain
    /// stays attached, so it is the only one of ours listed. Any other
    /// `mailboxship-` entry is a leftover from a run that crashed, and is
    /// dropped exactly as before.
    func attach() async {
        guard created, !attached else { return }
        await Self.searchList.run {
            // Appended, deliberately not `default-keychain`, which would
            // redirect every other tool's lookups for as long as it exists.
            let others = await Self.listedKeychains().filter { !$0.contains("mailboxship-") }
            _ = await Shell.run(
                "/usr/bin/security", ["list-keychains", "-d", "user", "-s", name] + others)
        }
        _ = await Shell.run("/usr/bin/security", ["unlock-keychain", "-p", password, name])
        attached = true
    }

    /// Take this keychain back off the search list. Safe to call when it is
    /// not attached.
    func detach() async {
        guard attached else { return }
        attached = false
        await Self.searchList.run {
            let others = await Self.listedKeychains().filter { !$0.contains("mailboxship-") }
            _ = await Shell.run("/usr/bin/security", ["list-keychains", "-d", "user", "-s"] + others)
        }
    }

    private static func listedKeychains() async -> [String] {
        let existing = await Shell.run("/usr/bin/security", ["list-keychains", "-d", "user"])
        return existing.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { !$0.isEmpty }
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

        await detach()
        _ = await Shell.run("/usr/bin/security", ["delete-keychain", name])
        log?("Removed temporary keychain \(name)\n")
    }
}
