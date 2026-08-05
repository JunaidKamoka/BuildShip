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
