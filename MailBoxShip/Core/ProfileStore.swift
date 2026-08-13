import Foundation
import SwiftUI

/// One saved set of project + credential settings.
///
/// Paths and identifiers only. The `.p8` is deliberately **not** stored — the
/// profile keeps a path to it and the file is read at the moment a token is
/// signed. Copying the key into this file would turn a convenience feature
/// into a store of live signing credentials for other people's accounts, which
/// is a materially different thing to be holding on disk.
struct ShipProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = "New profile"

    var projectPath: String = ""
    var scheme: String = ""
    var bundleID: String = ""
    var extensionBundleIDsRaw: String = ""

    var keyPath: String = ""
    var keyID: String = ""
    var issuerID: String = ""

    /// Path to the reusable signing identity (.p12).
    ///
    /// A certificate is only reusable if its private key survives, and this is
    /// where that key lives — a file you choose, on media you control, exactly
    /// like the .p8. Nothing is written to the Keychain and nothing is hidden
    /// on this machine: delete the file and every trace of the identity is
    /// gone. It is also portable, so the same identity works from another Mac
    /// without asking Apple for a second certificate.
    var identityPath: String = ""

    var marketingVersion: String = ""
    var buildNumber: String = ""

    /// Which platform to ship when the project builds more than one.
    ///
    /// Stored as the raw `ShipPlatform` value, empty meaning "follow whatever
    /// the project detects". A single scheme can build both a Mac and an iPhone
    /// app under the same bundle id, and detection can only report one of them —
    /// so without a saved choice the other platform can never be uploaded. Kept
    /// per profile because it is a property of this app, not of the session.
    var platformRaw: String = ""

    /// The user's explicit platform choice, or nil to follow detection.
    var platformOverride: ShipPlatform? {
        get { ShipPlatform(rawValue: platformRaw) }
        set { platformRaw = newValue?.rawValue ?? "" }
    }

    /// What detection last read from this project, remembered across launches.
    ///
    /// Detection is a multi-second `xcodebuild` call, but every field it needs
    /// to fill is already saved — so the Deploy button is live from the moment
    /// the window opens, well before the project has been read. Without this,
    /// the platform for that first run came from an in-memory default of iOS,
    /// and pressing Deploy early archived a Mac app with
    /// `-destination generic/platform=iOS`, which xcodebuild rejects with a
    /// list of destinations and no hint as to why one was asked for.
    var detectedPlatformRaw: String = ""

    /// The last detected platform, or nil if this project has never been read.
    var detectedPlatform: ShipPlatform? {
        get { ShipPlatform(rawValue: detectedPlatformRaw) }
        set { detectedPlatformRaw = newValue?.rawValue ?? "" }
    }

    /// The platform a run ships as, in order of authority: the user's explicit
    /// choice, then what this session detected, then what the last session
    /// detected. iOS only as the final resort, for a project nothing has yet
    /// managed to read.
    func shipPlatform(detected: ShipPlatform?) -> ShipPlatform {
        platformOverride ?? detected ?? detectedPlatform ?? .iOS
    }

    /// Permit revoking the oldest certificate when Apple refuses a new one.
    ///
    /// Saved with the store rather than held in view state: it used to reset on
    /// every launch, so a run that needed it silently failed at the same step
    /// with the toggle sitting innocently off.
    var allowCertificateReplacement = false

    var lastUsed: Date = Date()

    /// Egress proxy for this profile. Its password lives in the Keychain,
    /// keyed by `proxy.id` — never in this file.
    var proxy: ProxyConfig = ProxyConfig()

    // Beta App Review contact and demo account.
    //
    // Held per store because they genuinely differ per store: a different
    // client, a different support address, and a different demo login. Kept
    // locally so they survive between runs and are pushed to Apple on Save —
    // retyping them for every submission is exactly the friction this avoids.
    var reviewFirstName = ""
    var reviewLastName = ""
    var reviewEmail = ""
    var reviewPhone = ""
    var demoAccountName = ""
    var demoAccountRequired = false
    var reviewNotes = ""

    /// Keychain key for this store's demo password. Never the password itself.
    var demoPasswordKey: String { "demo-\(id.uuidString)" }

    /// Decoded field by field, tolerating anything absent.
    ///
    /// Swift's synthesised `Decodable` does **not** fall back to a property's
    /// default value when a key is missing — it throws. So every field added to
    /// this struct made files written by earlier builds undecodable, and the
    /// caller's `try?` quietly replaced them with an empty document. That is
    /// how a saved store could vanish after an update, with nothing to explain
    /// it. Decoding each key optionally means old files keep working and new
    /// fields simply start at their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ key: CodingKeys, _ fallback: String = "") -> String {
            (try? c.decodeIfPresent(String.self, forKey: key)) as? String ?? fallback
        }

        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) as? UUID ?? UUID()
        name = str(.name, "New profile")
        projectPath = str(.projectPath)
        scheme = str(.scheme)
        bundleID = str(.bundleID)
        extensionBundleIDsRaw = str(.extensionBundleIDsRaw)
        keyPath = str(.keyPath)
        keyID = str(.keyID)
        issuerID = str(.issuerID)
        identityPath = str(.identityPath)
        marketingVersion = str(.marketingVersion)
        buildNumber = str(.buildNumber)
        platformRaw = str(.platformRaw)
        detectedPlatformRaw = str(.detectedPlatformRaw)
        lastUsed = (try? c.decodeIfPresent(Date.self, forKey: .lastUsed)) as? Date ?? Date()
        proxy = (try? c.decodeIfPresent(ProxyConfig.self, forKey: .proxy)) as? ProxyConfig
            ?? ProxyConfig()
        allowCertificateReplacement =
            (try? c.decodeIfPresent(Bool.self, forKey: .allowCertificateReplacement)) as? Bool ?? false
        reviewFirstName = str(.reviewFirstName)
        reviewLastName = str(.reviewLastName)
        reviewEmail = str(.reviewEmail)
        reviewPhone = str(.reviewPhone)
        demoAccountName = str(.demoAccountName)
        demoAccountRequired =
            (try? c.decodeIfPresent(Bool.self, forKey: .demoAccountRequired)) as? Bool ?? false
        reviewNotes = str(.reviewNotes)
    }

    init() {}

    var extensionBundleIDs: [String] {
        extensionBundleIDsRaw
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Shown beside the name in the dropdown, so it is obvious which account a
    /// profile belongs to without opening it.
    var subtitle: String {
        let key = keyID.isEmpty ? "no key" : keyID
        return bundleID.isEmpty ? key : "\(bundleID) · \(key)"
    }

    /// Whether the referenced files are still where they were.
    ///
    /// A profile pointing at a moved project or a deleted key looks perfectly
    /// valid in a dropdown and then fails several minutes into a build; better
    /// to say so up front.
    var missingFiles: [String] {
        var out: [String] = []
        let fm = FileManager.default
        if !projectPath.isEmpty, !fm.fileExists(atPath: projectPath) {
            out.append("project")
        }
        if !keyPath.isEmpty, !fm.fileExists(atPath: keyPath) {
            out.append("API key")
        }
        return out
    }
}

/// Persists profiles and tracks which one is selected.
///
/// A JSON file under Application Support rather than UserDefaults: it holds a
/// list that grows, and keeping it as a plain file means the user can open it,
/// audit exactly what was saved, and delete it — which matters when the whole
/// point is that nothing sensitive is being retained.
@MainActor
final class ProfileStore: ObservableObject {

    @Published var profiles: [ShipProfile] = []
    @Published var selectedID: UUID?

    private var saveTask: Task<Void, Never>?

    init() {
        // One document holds profiles and secrets together, so a single file
        // is the whole of this tool's state.
        profiles = SecretStore.shared.profiles
        if profiles.isEmpty { profiles = [ShipProfile()] }
        selectedID = profiles.sorted { $0.lastUsed > $1.lastUsed }.first?.id
    }

    var storageDescription: String { SecretStore.shared.path }

    /// Distinct API credentials seen across every saved store.
    ///
    /// The Issuer ID is a property of the *account*, not of an app, so the
    /// same one is reused across every store on that account. Re-typing a
    /// 36-character UUID for each new store is pure friction, and mistyping it
    /// fails with an unexplained 401.
    struct KnownKey: Identifiable, Hashable {
        var id: String { keyID + issuerID }
        let keyID: String
        let issuerID: String
        let keyPath: String
        var label: String { "\(keyID) · \(issuerID.prefix(8))…" }
    }

    var knownKeys: [KnownKey] {
        var seen = Set<String>()
        var out: [KnownKey] = []
        for profile in profiles.sorted(by: { $0.lastUsed > $1.lastUsed }) {
            // Both halves are required: an entry with no Issuer ID applies
            // nothing useful and looks broken when picked.
            guard !profile.issuerID.isEmpty, !profile.keyID.isEmpty else { continue }
            let key = KnownKey(keyID: profile.keyID, issuerID: profile.issuerID,
                               keyPath: profile.keyPath)
            if seen.insert(key.id).inserted { out.append(key) }
        }
        return out
    }

    /// Apply a remembered credential set to the selected store.
    func applyKnownKey(_ key: KnownKey) {
        guard let selectedIndex else { return }
        profiles[selectedIndex].keyID = key.keyID
        profiles[selectedIndex].issuerID = key.issuerID
        if !key.keyPath.isEmpty { profiles[selectedIndex].keyPath = key.keyPath }
        scheduleSave()
    }

    /// Distinct proxy endpoints seen across every saved store.
    ///
    /// The gateway and login are the same for every store on one proxy plan —
    /// only the port differs, because that is what selects the sticky IP. So
    /// the endpoint is worth remembering and the port is not.
    struct KnownProxy: Identifiable, Hashable {
        var id: String { host + username }
        let host: String
        let username: String
        let sourceProxyID: String
        var label: String {
            username.isEmpty ? host : "\(username)@\(host)"
        }
    }

    var knownProxies: [KnownProxy] {
        var seen = Set<String>()
        var out: [KnownProxy] = []
        for profile in profiles.sorted(by: { $0.lastUsed > $1.lastUsed }) {
            let proxy = profile.proxy
            guard !proxy.host.isEmpty else { continue }
            let known = KnownProxy(host: proxy.host, username: proxy.username,
                                   sourceProxyID: proxy.id)
            if seen.insert(known.id).inserted { out.append(known) }
        }
        return out
    }

    /// Reuse a remembered endpoint, with a *new* sticky port so this store
    /// keeps its own exit IP rather than sharing the one it copied from.
    func applyKnownProxy(_ known: KnownProxy) {
        guard let selectedIndex else { return }
        let password = SecretStore.shared.get("proxy-\(known.sourceProxyID)")

        profiles[selectedIndex].proxy.enabled = true
        profiles[selectedIndex].proxy.host = known.host
        profiles[selectedIndex].proxy.username = known.username
        if !ProxyConfig.stickyPortRange.contains(profiles[selectedIndex].proxy.port) {
            profiles[selectedIndex].proxy.port =
                ProxyConfig.nextStickyPort(excluding: usedProxyPorts)
        }
        profiles[selectedIndex].proxy.savePassword(password)
        scheduleSave()
    }

    /// Sticky ports already claimed, so a new store never collides with an
    /// existing one and accidentally shares its exit IP.
    var usedProxyPorts: Set<Int> {
        Set(profiles.map(\.proxy.port).filter { ProxyConfig.stickyPortRange.contains($0) })
    }

    /// Give the selected profile the next free sticky port.
    func assignStickyPort() {
        guard let selectedIndex else { return }
        profiles[selectedIndex].proxy.port =
            ProxyConfig.nextStickyPort(excluding: usedProxyPorts)
        scheduleSave()
    }

    // MARK: - Selection

    var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return profiles.firstIndex { $0.id == selectedID }
    }

    var current: ShipProfile {
        guard let selectedIndex else { return ShipProfile() }
        return profiles[selectedIndex]
    }

    /// Two-way binding straight into the selected profile, so edits persist
    /// without every field needing its own plumbing.
    /// Binding into the selected profile's proxy.
    func proxyBinding<T>(_ keyPath: WritableKeyPath<ProxyConfig, T>, default fallback: T) -> Binding<T> {
        Binding(
            get: { [weak self] in self?.current.proxy[keyPath: keyPath] ?? fallback },
            set: { [weak self] newValue in
                guard let self, let index = self.selectedIndex else { return }
                self.profiles[index].proxy[keyPath: keyPath] = newValue
                self.scheduleSave()
            },
        )
    }

    /// Demo-account password, stored in the Keychain rather than the profile.
    func demoPasswordBinding() -> Binding<String> {
        Binding(
            get: { [weak self] in SecretStore.shared.get(self?.current.demoPasswordKey ?? "") },
            set: { [weak self] newValue in
                guard let self else { return }
                SecretStore.shared.set(newValue, for: self.current.demoPasswordKey)
            },
        )
    }

    func boolBinding(_ keyPath: WritableKeyPath<ShipProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.current[keyPath: keyPath] ?? false },
            set: { [weak self] newValue in
                guard let self, let index = self.selectedIndex else { return }
                self.profiles[index][keyPath: keyPath] = newValue
                self.scheduleSave()
            },
        )
    }

    /// The password is not part of the profile, so it needs its own accessor.
    func proxyPasswordBinding() -> Binding<String> {
        Binding(
            get: { [weak self] in self?.current.proxy.password() ?? "" },
            set: { [weak self] newValue in self?.current.proxy.savePassword(newValue) },
        )
    }

    func binding(_ keyPath: WritableKeyPath<ShipProfile, String>) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.current[keyPath: keyPath] ?? "" },
            set: { [weak self] newValue in
                guard let self, let index = self.selectedIndex else { return }
                self.profiles[index][keyPath: keyPath] = newValue
                self.scheduleSave()
            },
        )
    }

    // MARK: - Mutations

    func addProfile(named name: String = "New profile") {
        var profile = ShipProfile()
        profile.name = uniqueName(name)

        // Inherit the API credentials from the most recent store. A new store
        // is nearly always another app on the same account, so starting from a
        // blank Issuer ID means re-typing a UUID that never changes.
        if let recent = profiles.sorted(by: { $0.lastUsed > $1.lastUsed }).first {
            profile.keyPath = recent.keyPath
            profile.keyID = recent.keyID
            profile.issuerID = recent.issuerID
        }
        // Carry the most recent proxy across to a new store, since the usual
        // reason to have one is a network policy that applies to everything.
        // A fresh id keeps its password a separate Keychain entry.
        if let recent = profiles.sorted(by: { $0.lastUsed > $1.lastUsed }).first,
           !recent.proxy.host.isEmpty || !recent.proxy.username.isEmpty {
            var inherited = recent.proxy
            inherited.id = UUID().uuidString
            // Same host and credentials, but a *different port*: each store
            // gets its own sticky exit IP rather than sharing one. Editable
            // afterwards if the provider expects something specific.
            inherited.port = ProxyConfig.nextStickyPort(excluding: usedProxyPorts)
            inherited.savePassword(recent.proxy.password())
            profile.proxy = inherited
        }
        profiles.append(profile)
        selectedID = profile.id
        scheduleSave()
    }

    func duplicateSelected() {
        guard let selectedIndex else { return }
        var copy = profiles[selectedIndex]
        copy.id = UUID()
        // A distinct Keychain entry, so deleting one copy cannot strip the
        // other's password.
        let password = copy.proxy.password()
        copy.proxy.id = UUID().uuidString
        // A duplicate is a different store, so it gets its own sticky port.
        if copy.proxy.isUsable {
            copy.proxy.port = ProxyConfig.nextStickyPort(excluding: usedProxyPorts)
        }
        copy.proxy.savePassword(password)
        copy.name = uniqueName("\(copy.name) copy")
        copy.lastUsed = Date()
        profiles.append(copy)
        selectedID = copy.id
        scheduleSave()
    }

    func deleteSelected() {
        guard let selectedIndex else { return }
        // Remove the Keychain entries too; leaving orphaned secrets behind is
        // exactly the sort of residue this tool tries not to create.
        profiles[selectedIndex].proxy.deletePassword()
        SecretStore.shared.delete(profiles[selectedIndex].demoPasswordKey)
        profiles.remove(at: selectedIndex)
        // Never leave zero profiles — an empty dropdown gives the user nothing
        // to act on and no way back to a working state.
        if profiles.isEmpty { profiles = [ShipProfile()] }
        selectedID = profiles.first?.id
        scheduleSave()
    }

    func rename(to name: String) {
        guard let selectedIndex, !name.isEmpty else { return }
        profiles[selectedIndex].name = name
        scheduleSave()
    }

    /// Called when a build starts, so the dropdown orders by recency.
    func markUsed() {
        guard let selectedIndex else { return }
        profiles[selectedIndex].lastUsed = Date()
        scheduleSave()
    }

    /// Fill in the Key ID from the conventional filename, saving one field.
    ///
    /// The filename wins over whatever is in the field, rather than only filling
    /// a blank one. `AuthKey_<KeyID>.p8` states the key's identity outright, and
    /// the common way to get here is swapping the key on an existing profile —
    /// where leaving the previous Key ID in place silently pairs a new key with
    /// the wrong id, and the run fails at authentication with nothing on screen
    /// to explain it.
    func adoptKey(path: String) {
        guard let selectedIndex else { return }
        profiles[selectedIndex].keyPath = path

        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("AuthKey_"), name.hasSuffix(".p8") else {
            scheduleSave()
            return
        }
        let keyID = String(name.dropFirst("AuthKey_".count).dropLast(".p8".count))
        profiles[selectedIndex].keyID = keyID

        // The Key ID and Issuer ID together identify an account, so a key the
        // tool has seen before also settles the issuer — from a saved profile,
        // or failing that the baked registry, which is what lets a fresh machine
        // resolve the issuer from the key filename alone.
        //
        // An issuer already on screen is only replaced when the new key is
        // known to belong to a different account. Several keys can share one
        // issuer, so an unrecognised key is no reason to clear a correct value.
        let known = profiles.first(where: { $0.keyID == keyID && !$0.issuerID.isEmpty })?.issuerID
            ?? Deployment.issuer(forKeyID: keyID)
        if let known {
            profiles[selectedIndex].issuerID = known
        }
        scheduleSave()
    }

    // MARK: - Baked deployment config

    /// Apply the committed proxy to the selected profile if it has none of its
    /// own yet, so a fresh machine routes App Store Connect traffic through the
    /// shared gateway without anyone having to enter — or even see — it. A proxy
    /// already configured by hand in the advanced screen is left untouched.
    func applyBakedProxyIfNeeded() {
        guard Deployment.proxyConfigured, let index = selectedIndex,
              profiles[index].proxy.host.isEmpty else { return }

        var proxy = profiles[index].proxy
        proxy.enabled = true
        proxy.host = Deployment.proxy.host
        proxy.username = Deployment.proxy.username

        switch Deployment.proxy.stickiness {
        case .port:
            if !ProxyConfig.stickyPortRange.contains(proxy.port) {
                proxy.port = ProxyConfig.nextStickyPort(excluding: usedProxyPorts)
            }
        case .session:
            if proxy.port == 0 { proxy.port = ProxyConfig.stickyPortRange.lowerBound }
            if proxy.sessionSuffix.isEmpty { proxy.sessionSuffix = ProxyConfig.newSessionSuffix() }
        }

        proxy.savePassword(Deployment.proxy.password)
        profiles[index].proxy = proxy
        scheduleSave()
    }

    /// Move this profile to a new stable exit IP — the "New IP" action. Rotates
    /// whichever knob the provider keys stickiness on, so the address actually
    /// changes rather than just looking like it might.
    func rotateProxyIP() {
        guard let index = selectedIndex else { return }
        switch Deployment.proxy.stickiness {
        case .session:
            profiles[index].proxy.sessionSuffix = ProxyConfig.newSessionSuffix()
        case .port:
            profiles[index].proxy.port = ProxyConfig.nextStickyPort(excluding: usedProxyPorts)
        }
        scheduleSave()
    }

    /// Name the profile after the project the first time one is chosen, so a
    /// list of saved profiles is readable rather than "New profile" repeated.
    func adoptProject(path: String) {
        guard let selectedIndex else { return }
        let replacesAnotherProject = !profiles[selectedIndex].projectPath.isEmpty
            && profiles[selectedIndex].projectPath != path
        profiles[selectedIndex].projectPath = path

        let base = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".xcodeproj", with: "")
        if profiles[selectedIndex].scheme.isEmpty {
            profiles[selectedIndex].scheme = base
        }

        // Version overrides belong to the app that was here before. Blank means
        // "use the project's own numbers", which is the only defensible start
        // for one just chosen — a leftover override silently stamps another
        // app's version and build onto this one, and a build number is spent
        // the moment it reaches Apple.
        //
        // The platform belongs to the app that was here before for the same
        // reason: an iPhone app shipped from this profile leaves an explicit
        // iOS choice behind, and a Mac project adopted afterwards is then
        // pinned to iOS by a picker the user last touched for another app.
        // Clearing both returns the profile to following detection.
        if replacesAnotherProject {
            profiles[selectedIndex].marketingVersion = ""
            profiles[selectedIndex].buildNumber = ""
            profiles[selectedIndex].platformRaw = ""
            profiles[selectedIndex].detectedPlatformRaw = ""
        }
        if profiles[selectedIndex].name == "New profile" {
            profiles[selectedIndex].name = uniqueName(base)
        }
        scheduleSave()
    }

    // MARK: - Validation

    func problems() -> [String] {
        let p = current
        var out: [String] = []
        let fm = FileManager.default

        if p.projectPath.isEmpty { out.append("Choose your .xcodeproj") }
        else if !fm.fileExists(atPath: p.projectPath) {
            out.append("That project path no longer exists")
        }
        if p.scheme.isEmpty { out.append("Enter the scheme name") }
        if p.bundleID.isEmpty { out.append("Enter the app's bundle identifier") }
        if p.keyPath.isEmpty { out.append("Choose your App Store Connect .p8 key") }
        else if !fm.fileExists(atPath: p.keyPath) {
            out.append("That .p8 file no longer exists")
        }
        if p.keyID.isEmpty { out.append("Enter the Key ID") }
        if p.issuerID.isEmpty { out.append("Enter the Issuer ID") }
        return out
    }

    /// Key IDs are exactly ten characters; catching it here avoids a round trip
    /// that fails with an unexplained 401.
    var keyIDLooksWrong: Bool {
        let value = current.keyID
        return !value.isEmpty && value.count != 10
    }

    /// Issuer IDs are UUIDs. Pasting the Key ID here is the commonest mistake.
    var issuerLooksWrong: Bool {
        let value = current.issuerID
        return !value.isEmpty && UUID(uuidString: value) == nil
    }

    // MARK: - Persistence

    private func uniqueName(_ proposed: String) -> String {
        var name = proposed
        var suffix = 2
        while profiles.contains(where: { $0.name == name }) {
            name = "\(proposed) \(suffix)"
            suffix += 1
        }
        return name
    }

    /// Debounced: field bindings fire per keystroke, and writing the file on
    /// each one would be a lot of disk churn for no benefit.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        SecretStore.shared.profiles = profiles
    }

    /// Re-read after the data file has been moved or replaced.
    func reload() {
        profiles = SecretStore.shared.profiles
        if profiles.isEmpty { profiles = [ShipProfile()] }
        if selectedID == nil || !profiles.contains(where: { $0.id == selectedID }) {
            selectedID = profiles.sorted { $0.lastUsed > $1.lastUsed }.first?.id
        }
    }
}
