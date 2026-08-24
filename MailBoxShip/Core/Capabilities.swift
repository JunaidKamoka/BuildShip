import Foundation

/// Maps entitlements the project declares to the App ID capabilities Apple
/// requires for them.
///
/// This exists because the failure it prevents is genuinely opaque. Declaring
/// an entitlement whose capability is not enabled on the App ID does not
/// produce a message about capabilities — it fails the *archive* with
/// "requires a provisioning profile with the … feature", which points at the
/// profile rather than at the App ID that the profile was generated from.
/// Reading the entitlements and turning on what they imply removes a whole
/// class of that confusion.
enum Capabilities {

    /// Entitlement key → App Store Connect `capabilityType`.
    ///
    /// Only entitlements that *have* a corresponding capability are listed.
    /// Several common ones (keychain-access-groups, get-task-allow,
    /// application-identifier) are implicit and have no capability to enable.
    static let map: [String: String] = [
        "aps-environment": "PUSH_NOTIFICATIONS",
        "com.apple.security.application-groups": "APP_GROUPS",
        "com.apple.developer.associated-domains": "ASSOCIATED_DOMAINS",
        "com.apple.developer.icloud-container-identifiers": "ICLOUD",
        "com.apple.developer.icloud-services": "ICLOUD",
        "com.apple.developer.ubiquity-kvstore-identifier": "ICLOUD",
        "com.apple.developer.in-app-payments": "APPLE_PAY",
        "com.apple.developer.healthkit": "HEALTHKIT",
        "com.apple.developer.homekit": "HOMEKIT",
        "com.apple.developer.networking.wifi-info": "ACCESS_WIFI_INFORMATION",
        "com.apple.developer.networking.vpn.api": "PERSONAL_VPN",
        "com.apple.developer.networking.networkextension": "NETWORK_EXTENSIONS",
        "com.apple.developer.networking.multipath": "MULTIPATH",
        "com.apple.developer.siri": "SIRIKIT",
        "com.apple.developer.game-center": "GAME_CENTER",
        "inter-app-audio": "INTER_APP_AUDIO",
        "com.apple.developer.default-data-protection": "DATA_PROTECTION",
        "com.apple.developer.nfc.readersession.formats": "NFC_TAG_READING",
        "com.apple.developer.ClassKit-environment": "CLASSKIT",
        "com.apple.developer.authentication-services.autofill-credential-provider":
            "AUTOFILL_CREDENTIAL_PROVIDER",
        "com.apple.developer.applesignin": "APPLE_ID_AUTH",
        "com.apple.developer.usernotifications.time-sensitive":
            "USERNOTIFICATIONS_TIMESENSITIVE",
        "com.apple.developer.group-session": "GROUP_ACTIVITIES",
        "com.apple.developer.family-controls": "FAMILY_CONTROLS",
        "com.apple.developer.user-fonts": "FONT_INSTALLATION",
        "com.apple.developer.coremedia.hls.low-latency": "HLS_INTERSTITIAL_PREVIEW",
        "com.apple.developer.devicecheck.appattest-environment": "APP_ATTEST",
        "com.apple.developer.kernel.increased-memory-limit": "INCREASED_MEMORY_LIMIT",
        "com.apple.developer.push-to-talk": "PUSH_TO_TALK",
        "com.apple.developer.media-device-discovery-extension":
            "MEDIA_DEVICE_DISCOVERY",
        "com.apple.developer.on-demand-install-capable": "ON_DEMAND_INSTALL_CAPABLE",
    ]

    /// Capabilities every iOS App ID should carry regardless of entitlements.
    ///
    /// In-App Purchase is normally on by default, but an App ID created
    /// through the API does not always get it — and discovering that during a
    /// store submission is far more expensive than asserting it here.
    static let alwaysOn = ["IN_APP_PURCHASE"]

    /// Capabilities Apple will not turn on from a `capabilityType` alone.
    ///
    /// The portal's toggle for these asks a second question, and the API
    /// expects that answer in the create request rather than defaulting it.
    /// Sign in with Apple is the one that matters in practice: its toggle also
    /// declares whether this App ID is the *primary* one of a sign-in group,
    /// which is what a single app always is.
    ///
    /// Anything needing a setting that cannot be guessed — a data protection
    /// level is a real choice about the app, not a formality — is deliberately
    /// absent, so Apple refuses it and the refusal is reported rather than a
    /// level being picked on someone's behalf.
    static let settings: [String: [[String: Any]]] = [
        "APPLE_ID_AUTH": [[
            "key": "APPLE_ID_AUTH_APP_CONSENT",
            "options": [["key": "PRIMARY_APP_CONSENT"]],
        ]],
        "ICLOUD": [[
            "key": "ICLOUD_VERSION",
            "options": [["key": "XCODE_6"]],
        ]],
    ]

    /// Entitlements safe to take from a provisioning profile when the target
    /// itself declares none.
    ///
    /// A capability enabled on the App ID lands in the profile, but the profile
    /// only grants permission — the shipped binary still has to *claim* the
    /// entitlement, and that claim comes from the project. A target that never
    /// got an entitlements file therefore ships without it: Sign in with Apple
    /// is enabled on the App ID, the profile carries it, the build uploads
    /// cleanly, and the button fails on a real device with nothing to explain
    /// why. Adopting the key from the profile closes that gap.
    ///
    /// Restricted to capabilities that name nothing outside the app. An app
    /// group, an iCloud container or an associated domain is a claim on a
    /// specific external resource, and taking a team's whole list because the
    /// profile happens to carry it would sign an app for things it has no
    /// business claiming. These are the ones that are simply on or off, and the
    /// value used is the profile's own — nothing here is invented.
    static let adoptable: Set<String> = [
        "aps-environment",
        "com.apple.developer.applesignin",
        "com.apple.developer.devicecheck.appattest-environment",
        "com.apple.developer.game-center",
        "com.apple.developer.healthkit",
        "com.apple.developer.siri",
        "com.apple.developer.kernel.increased-memory-limit",
        "com.apple.developer.usernotifications.time-sensitive",
        "com.apple.developer.group-session",
        "com.apple.developer.family-controls",
        "com.apple.developer.push-to-talk",
        "com.apple.developer.on-demand-install-capable",
    ]

    /// Entitlements with no API-settable capability.
    ///
    /// Communication Notifications is the one that matters in practice: the
    /// App Store Connect API rejects every spelling of it, because Apple only
    /// exposes that toggle in the developer portal. Naming it explicitly turns
    /// a mystifying archive failure into one sentence of instruction.
    static let portalOnly: [String: String] = [
        "com.apple.developer.usernotifications.communication":
            "Communication Notifications — enable it at developer.apple.com → "
            + "Identifiers → your App ID, or remove the entitlement.",
    ]

    /// Read the entitlement keys an entitlements plist declares.
    static func entitlementKeys(atPath path: String) -> [String] {
        guard
            !path.isEmpty,
            let data = FileManager.default.contents(atPath: path),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else { return [] }
        return Array(plist.keys)
    }

    /// What to enable, and what cannot be enabled, for a set of entitlements.
    static func resolve(entitlementKeys keys: [String]) -> (
        enable: [String], manual: [String]
    ) {
        var enable = Set(alwaysOn)
        var manual: [String] = []

        for key in keys {
            if let capability = map[key] {
                enable.insert(capability)
            } else if let note = portalOnly[key] {
                manual.append(note)
            }
        }
        return (enable.sorted(), manual)
    }
}
