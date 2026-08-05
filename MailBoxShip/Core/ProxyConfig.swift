import Foundation

/// Optional HTTP proxy for outbound App Store Connect traffic.
///
/// Present because some networks require all egress to pass through a proxy —
/// a normal constraint for a build tool. Two things it is deliberately *not*:
///
///  - It is not a way to stop Apple associating developer accounts. Apple
///    correlates on Apple ID sign-ins, device identifiers, payment instruments
///    and legal entity, not on the source IP of an upload. Using an API key
///    rather than an Apple ID — which this tool already does — is what
///    actually keeps accounts separate.
///  - It is not a privacy boundary against the proxy operator. HTTPS to Apple
///    is tunnelled with CONNECT, so the operator sees the destination host and
///    traffic volume but not the contents.
///
/// The password lives in the Keychain, never in the profile JSON, because that
/// file is plain text the user is explicitly invited to open and inspect.
struct ProxyConfig: Codable, Hashable {
    var enabled = false
    var host = ""
    var port = 0
    var username = ""

    /// Provider-specific suffix that pins this profile to one sticky IP.
    ///
    /// Residential providers encode session stickiness in the username — the
    /// base login plus a session token — so two profiles with different
    /// suffixes hold two different, stable exit IPs, while the same suffix
    /// always returns to the same one.
    ///
    /// Free text because the syntax differs per provider (`__sessid-x`,
    /// `-session-x`, `;sess=x` and others are all in use). It is generated
    /// unique per profile and then left alone; check your provider's docs for
    /// the exact token they expect.
    var sessionSuffix = ""

    /// Never encoded. Read from the Keychain on demand, keyed by `id`.
    var id = UUID().uuidString

    /// Same reasoning as ShipProfile: missing keys must not throw, or adding a
    /// field silently discards every saved proxy.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) as? Bool ?? false
        host = (try? c.decodeIfPresent(String.self, forKey: .host)) as? String ?? ""
        port = (try? c.decodeIfPresent(Int.self, forKey: .port)) as? Int ?? 0
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) as? String ?? ""
        sessionSuffix = (try? c.decodeIfPresent(String.self, forKey: .sessionSuffix)) as? String ?? ""
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) as? String ?? UUID().uuidString
    }

    init() {}

    var isUsable: Bool { enabled && !host.isEmpty && port > 0 }

    /// Login actually sent to the proxy: the base username plus the sticky
    /// session token.
    var effectiveUsername: String { username + sessionSuffix }

    var summary: String {
        guard isUsable else { return "Direct connection" }
        return username.isEmpty
            ? "\(host):\(port)"
            : "\(effectiveUsername)@\(host):\(port)"
    }

    /// A fresh session token, so a new store gets its own stable exit IP
    /// rather than sharing one with an existing store.
    ///
    /// Only needed by providers that key stickiness on the username. Where the
    /// port selects the session instead — the common residential setup, and
    /// what `stickyPortRange` covers — leave this empty.
    static func newSessionSuffix() -> String {
        "__sessid-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
    }

    /// Ports that map to distinct sticky sessions.
    ///
    /// Residential providers commonly expose one gateway host across a port
    /// range, where each port holds its own stable exit IP for the life of the
    /// session. Assigning a different port per store is therefore how each
    /// store keeps a consistent address — no rotation, no shared IP.
    static let stickyPortRange = 10_000...20_000

    /// Lowest port in the range not already taken by another store.
    ///
    /// Sequential rather than random so the assignment is predictable and easy
    /// to reconcile against the provider's dashboard.
    static func nextStickyPort(excluding taken: Set<Int>) -> Int {
        for port in stickyPortRange where !taken.contains(port) { return port }
        return stickyPortRange.lowerBound
    }

    // MARK: - Password storage

    /// Stored in the secrets file, or held only for this session when none is
    /// configured. Never in the profile JSON and never in the Keychain.
    private var secretKey: String { "proxy-\(id)" }

    @MainActor func savePassword(_ password: String) {
        SecretStore.shared.set(password, for: secretKey)
    }

    @MainActor func password() -> String {
        SecretStore.shared.get(secretKey)
    }

    @MainActor func deletePassword() {
        SecretStore.shared.delete(secretKey)
    }

    // MARK: - Applying

    /// Proxy dictionary for URLSession, used by the App Store Connect calls.
    @MainActor var sessionProxyDictionary: [AnyHashable: Any]? {
        guard isUsable else { return nil }
        // HTTPS to Apple is tunnelled via CONNECT, so only the HTTPS keys
        // matter; setting the HTTP ones too covers any plain redirect.
        var dict: [AnyHashable: Any] = [
            kCFNetworkProxiesHTTPEnable: 1,
            kCFNetworkProxiesHTTPProxy: host,
            kCFNetworkProxiesHTTPPort: port,
            "HTTPSEnable": 1,
            "HTTPSProxy": host,
            "HTTPSPort": port,
        ]
        if !username.isEmpty {
            dict[kCFProxyUsernameKey] = effectiveUsername
            dict[kCFProxyPasswordKey] = password()
        }
        return dict
    }

    /// Environment for the command-line tools.
    ///
    /// `altool` and `xcodebuild` do not use this app's URLSession, so they are
    /// steered with the conventional proxy variables instead. Credentials go in
    /// the URL because that is the only form these tools accept — which is also
    /// why they are never logged.
    @MainActor var toolEnvironment: [String: String] {
        guard isUsable else { return [:] }

        var authority = "\(host):\(port)"
        if !username.isEmpty {
            let user = effectiveUsername.addingPercentEncoding(
                withAllowedCharacters: .urlUserAllowed) ?? effectiveUsername
            let pass = password().addingPercentEncoding(
                withAllowedCharacters: .urlPasswordAllowed) ?? ""
            authority = pass.isEmpty ? "\(user)@\(authority)" : "\(user):\(pass)@\(authority)"
        }
        let url = "http://\(authority)"

        return [
            "HTTP_PROXY": url, "http_proxy": url,
            "HTTPS_PROXY": url, "https_proxy": url,
            // Apple's upload endpoints only; never route localhost through it.
            "NO_PROXY": "localhost,127.0.0.1,::1",
        ]
    }

    /// Safe to print — the password is replaced, not merely truncated.
    @MainActor var redactedDescription: String {
        guard isUsable else { return "direct" }
        return username.isEmpty
            ? "\(host):\(port)"
            : "\(effectiveUsername):••••••@\(host):\(port)"
    }
}
