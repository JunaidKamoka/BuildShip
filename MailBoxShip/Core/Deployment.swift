import Foundation

/// Baked-in deployment configuration — the single place to edit the shared
/// egress proxy and the per-key App Store Connect Issuer IDs.
///
/// Committed to source on purpose, so a freshly built copy of the app on any
/// Mac already knows the proxy and every client's issuer with nothing to set
/// up. The trade-off is that the proxy password lives in git history: if that
/// ever matters, rotate it at the provider rather than trying to scrub it here.
///
/// None of this is shown in the simple UI. Users only pick a project folder and
/// a `.p8` key; everything below is resolved for them.
enum Deployment {

    // MARK: - Proxy

    struct ProxyDefaults {
        var host: String
        var username: String
        var password: String

        /// How the provider pins one stable exit IP, and therefore what the
        /// "New IP" button rotates.
        ///
        ///  - `.port`: each profile takes a port in `ProxyConfig.stickyPortRange`
        ///    and that port *is* the session. The residential default.
        ///  - `.session`: one port for everyone; a token appended to the
        ///    username selects the session instead.
        var stickiness: Stickiness
        enum Stickiness { case port, session }
    }

    /// Fill in `host` (and usually the credentials) to switch the baked proxy
    /// on. Leave `host` empty to ship with no proxy — the simple screen then
    /// hides the network row entirely and connects directly.
    static let proxy = ProxyDefaults(
        host: "",         // e.g. "gw.yourprovider.com"
        username: "",     // e.g. "user-xxxxxxxx"
        password: "",     // e.g. "••••••••"
        stickiness: .port,
    )

    static var proxyConfigured: Bool { !proxy.host.isEmpty }

    // MARK: - Issuer IDs

    /// KeyID → Issuer ID. The KeyID is the ten characters in the key's filename
    /// (`AuthKey_<KeyID>.p8`); the Issuer ID is the account-level UUID from
    /// App Store Connect → Users and Access → Integrations.
    ///
    /// Add one line per client. Dropping that client's `.p8` then resolves the
    /// issuer automatically, so the whole flow stays "folder + key → Deploy".
    static let issuerByKeyID: [String: String] = [:]
    // Add clients here, e.g.:
    //   "T8W7M97Q23": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",  // Stephen Wilson
    // by replacing the [:] above with a populated literal:
    //   static let issuerByKeyID: [String: String] = [
    //       "T8W7M97Q23": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    //   ]

    /// Used when a dropped key is not in `issuerByKeyID`. Leave `nil` to instead
    /// fall back to a previously-saved profile, and finally to a one-time field
    /// the simple screen shows only when the issuer is still unknown.
    static let defaultIssuer: String? = nil

    /// Resolve an Issuer ID for a KeyID from the baked config, or `nil` if this
    /// key is not configured here (the UI then fills the gap).
    static func issuer(forKeyID keyID: String) -> String? {
        issuerByKeyID[keyID] ?? defaultIssuer
    }

    // MARK: - Cloud sync (Firebase)

    /// The Firebase project that backs profile + key sync across machines.
    ///
    /// Both values are client-side identifiers, safe to commit: the Web API key
    /// is the very one already shipped in the app's `GoogleService-Info.plist`,
    /// and it grants nothing on its own — Firestore access is gated by Auth and
    /// the security rules, not by this key. Sync is simply off when either is
    /// blank. One-time console step: enable Anonymous auth on this project.
    static let firebaseProjectID = "mailbox-a2142"
    static let firebaseAPIKey = "AIzaSyD0nfjamfyJbozG8ChVCh3L-mLuWOTbAV4"

    static var syncConfigured: Bool { !firebaseProjectID.isEmpty && !firebaseAPIKey.isEmpty }
}
