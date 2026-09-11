import Foundation

/// The platform a scheme builds for.
///
/// Everything the pipeline does that differs between an iPhone app and a Mac
/// app keys off this: the archive destination, the App Store profile type, the
/// App ID platform, whether export produces a `.pkg` needing an installer
/// certificate, and the `altool` platform on validate and upload.
enum ShipPlatform: String, Sendable, CaseIterable, Identifiable {
    case iOS
    case macOS
    /// An iOS app built for the Mac. It is neither of the other two: it archives
    /// from the iOS target against the macOS SDK, ships as a `.pkg` like a Mac
    /// app, and needs its own `MAC_CATALYST_APP_STORE` profile type — a Mac App
    /// Store profile is refused at export ("is not a Mac Catalyst App Store
    /// profile"), which is the failure this case exists to prevent.
    case macCatalyst

    var id: String { rawValue }

    /// How the platform is named in the UI — the picker label and any prose.
    var displayName: String {
        switch self {
        case .iOS: "iOS"
        case .macOS: "macOS"
        case .macCatalyst: "Mac Catalyst"
        }
    }

    /// The SF Symbol standing in for the platform beside its selector.
    var symbol: String {
        switch self {
        case .iOS: "iphone"
        case .macOS: "desktopcomputer"
        case .macCatalyst: "macwindow"
        }
    }
}

/// Reads a project and reports what is actually in it.
///
/// Every value this fills in — scheme, bundle identifiers, version, build —
/// is one the user would otherwise have to type correctly from memory, and
/// each one fails late and unhelpfully when wrong. A mistyped bundle id does
/// not fail until export, several minutes in, with "No profiles for …". Asking
/// the project is both faster and more accurate than asking the person.
enum ProjectInspector {

    struct Info {
        var schemes: [String] = []
        /// What the app target builds for, or nil when the project has not been
        /// read yet. Drives the whole macOS-vs-iOS split downstream, which is
        /// exactly why "not read yet" must not be spelled `.iOS`: a default that
        /// names a real platform is indistinguishable from a detected one, and
        /// a Mac-only scheme then archives for iOS and fails on the destination.
        /// Callers that need a value choose their own fallback, knowingly.
        var platform: ShipPlatform?
        var bundleID = ""
        /// Extensions and other embedded targets, which each need their own
        /// App ID and provisioning profile.
        var extensionBundleIDs: [String] = []
        var marketingVersion = ""
        var buildNumber = ""
        var team = ""
        /// Absolute entitlements path per bundle id, so each App ID can be
        /// given exactly the capabilities its own target asks for.
        var entitlements: [String: String] = [:]
        /// Resolved build settings per bundle id. Entitlements files reference
        /// project-defined settings — a `$(BASE_PACKAGE_IDENTIFIER)` shared
        /// between an app and its extensions — and only the project can say
        /// what those are worth.
        var buildSettings: [String: [String: String]] = [:]

        var summary: String {
            var parts: [String] = []
            parts.append("\(schemes.count) scheme\(schemes.count == 1 ? "" : "s")")
            if !bundleID.isEmpty { parts.append(bundleID) }
            if !extensionBundleIDs.isEmpty {
                parts.append("+\(extensionBundleIDs.count) extension\(extensionBundleIDs.count == 1 ? "" : "s")")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Resolve whatever the user picked into an actual `.xcodeproj`.
    ///
    /// `.xcodeproj` is a package, so the open panel has to allow directories —
    /// which means it also allows picking the *enclosing* folder by mistake.
    /// That is an easy error to make and produces a baffling failure later, so
    /// it is worth correcting here rather than rejecting.
    static func resolveProject(at path: String) -> String? {
        let fm = FileManager.default

        if path.hasSuffix(".xcodeproj") {
            // A valid project is taken as chosen. An *invalid* one — a bundle
            // missing its project.pbxproj, typically a rename leftover like
            // `Craftly.xcodeproj` sitting beside the real `CriFly.xcodeproj` —
            // is treated like picking its folder, so the valid sibling wins
            // instead of failing with "missing its project.pbxproj file".
            if isValidProject(path) { return path }
            let parent = (path as NSString).deletingLastPathComponent
            return firstProject(in: parent, using: fm) ?? path
        }

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        // Look in the folder, then one level down — repositories commonly keep
        // the project in an `ios/` or `App/` subdirectory.
        if let direct = firstProject(in: path, using: fm) { return direct }

        let children = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        for child in children.sorted() {
            let sub = (path as NSString).appendingPathComponent(child)
            var subIsDir: ObjCBool = false
            guard fm.fileExists(atPath: sub, isDirectory: &subIsDir), subIsDir.boolValue,
                  !child.hasPrefix(".") else { continue }
            if let found = firstProject(in: sub, using: fm) { return found }
        }
        return nil
    }

    /// Whether a `.xcodeproj` bundle is actually openable.
    ///
    /// Every real project keeps its contents in a `project.pbxproj` inside the
    /// bundle. A bundle without one (a rename leftover, a partial checkout)
    /// makes xcodebuild fail with "cannot be opened because it is missing its
    /// project.pbxproj file", so it must never be picked over a valid sibling.
    static func isValidProject(_ path: String) -> Bool {
        path.hasSuffix(".xcodeproj")
            && FileManager.default.fileExists(
                atPath: (path as NSString).appendingPathComponent("project.pbxproj"))
    }

    /// The best `.xcodeproj` in a directory: a valid one over a broken one, and
    /// alphabetical order only to break ties among equals.
    private static func firstProject(in directory: String, using fm: FileManager) -> String? {
        let projects = ((try? fm.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".xcodeproj") }
            .sorted()
            .map { (directory as NSString).appendingPathComponent($0) }
        return projects.first(where: isValidProject) ?? projects.first
    }

    /// How `xcodebuild` should be pointed at a project: the bare `.xcodeproj`,
    /// or the `.xcworkspace` that must be used instead when one exists.
    enum Container {
        case project(String)
        case workspace(String)

        var arguments: [String] {
            switch self {
            case .project(let path): ["-project", path]
            case .workspace(let path): ["-workspace", path]
            }
        }
    }

    /// Prefer a sibling `.xcworkspace` over the bare project whenever one sits
    /// beside it.
    ///
    /// CocoaPods integrates its `Pods` target through a generated
    /// `<App>.xcworkspace`; archiving the `.xcodeproj` alone leaves every pod
    /// unlinked and the build dies on the first `import` with "Unable to find
    /// module dependency: '<Pod>'". The workspace convention is a sibling of the
    /// project sharing its name, so prefer that; a single unrelated workspace in
    /// the folder is still unambiguous, but two or more are not — there, stay
    /// with the explicit project rather than guess.
    ///
    /// Only the parent directory is inspected, never the `project.xcworkspace`
    /// that lives *inside* every `.xcodeproj` bundle — that one is Xcode's own,
    /// not a CocoaPods workspace, and building it would archive nothing.
    static func container(forProjectPath projectPath: String) -> Container {
        let fm = FileManager.default
        let directory = (projectPath as NSString).deletingLastPathComponent
        let base = ((projectPath as NSString).lastPathComponent as NSString).deletingPathExtension

        let workspaces = ((try? fm.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".xcworkspace") }

        let chosen = workspaces.first { ($0 as NSString).deletingPathExtension == base }
            ?? (workspaces.count == 1 ? workspaces.first : nil)

        if let chosen {
            return .workspace((directory as NSString).appendingPathComponent(chosen))
        }
        return .project(projectPath)
    }

    /// Schemes and targets, from `xcodebuild -list`.
    ///
    /// Both are needed, because the scheme list alone is misleading: Swift
    /// Package dependencies contribute schemes of their own — "GRDB-Package"
    /// and the like — and they sort alphabetically ahead of the real one.
    /// Picking the first scheme blindly therefore tries to archive a
    /// dependency, which fails in a thoroughly confusing way.
    static func list(projectPath: String) async -> (schemes: [String], targets: [String]) {
        let result = await Shell.run("/usr/bin/xcodebuild",
            container(forProjectPath: projectPath).arguments + ["-list", "-json"])
        guard
            result.succeeded,
            let json = firstJSON(in: result.output, opening: "{") as? [String: Any]
        else { return ([], []) }

        // A project lists its schemes and targets under "project"; a workspace
        // (CocoaPods, or any multi-project workspace) lists schemes under
        // "workspace" and carries no targets of its own.
        let node = (json["project"] as? [String: Any])
            ?? (json["workspace"] as? [String: Any]) ?? [:]
        let schemes = node["schemes"] as? [String] ?? []
        let targets = node["targets"] as? [String] ?? []

        // A scheme that shares its name with a target belongs to this project;
        // a package's does not. Ordering that way makes the first entry the
        // right default, and keeps the others available in the dropdown.
        let ranked = schemes.sorted { a, b in
            let aIsLocal = targets.contains(a)
            let bIsLocal = targets.contains(b)
            if aIsLocal != bIsLocal { return aIsLocal }
            return a < b
        }
        return (ranked, targets)
    }

    /// Everything else, from the resolved build settings of one scheme.
    ///
    /// `-showBuildSettings` returns one entry per target the scheme's build
    /// action names, which is what makes the extension bundle ids discoverable
    /// — they are simply the non-application targets. Parsing the `.pbxproj` by
    /// hand would find the same strings but could not tell which target they
    /// belonged to, nor resolve `$(...)` variables.
    ///
    /// What the scheme names is not always every target that ships, though, so
    /// the leftovers are asked for separately below.
    static func inspect(projectPath: String, scheme: String) async -> Info {
        var info = Info()
        var hostCameFromScheme = false
        /// Bundle ids whose settings came from the scheme's own targets.
        var settingsCameFromScheme: Set<String> = []

        var entries = await buildSettings(
            container: container(forProjectPath: projectPath).arguments,
            selecting: ["-scheme", scheme])
        let schemeTargets = Set(entries.compactMap { $0["target"] as? String })
        entries += await settingsForTargetsMissing(from: entries, projectPath: projectPath)

        guard !entries.isEmpty else { return info }

        for entry in entries {
            guard let settings = entry["buildSettings"] as? [String: Any] else { continue }
            let bundle = settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String ?? ""
            guard !bundle.isEmpty else { continue }

            // A workspace build also reports the CocoaPods and SPM framework and
            // library targets. Their bundle ids (org.cocoapods.*) are not the
            // app's, and letting one land in `info.bundleID` would sign and ship
            // under the wrong identifier, so skip anything that is not an app or
            // an app-extension.
            let productType = settings["PRODUCT_TYPE"] as? String ?? ""
            if bundle.hasPrefix("org.cocoapods.")
                || productType == "com.apple.product-type.framework"
                || productType.hasPrefix("com.apple.product-type.library") {
                continue
            }

            // The wrapper extension distinguishes the app from what it embeds:
            // ".app" for the host, ".appex" for extensions.
            let wrapper = settings["WRAPPER_EXTENSION"] as? String ?? ""
            let fromScheme = (entry["target"] as? String).map(schemeTargets.contains) ?? false

            // Two targets may share one bundle id: an iPhone app and a Mac app
            // under a single App Store record is exactly that, and it is what
            // universal purchase requires. These maps are keyed by identifier,
            // so without a tiebreak the leftover target overwrites the one the
            // scheme actually builds — and the run then reads the other
            // platform's SUPPORTED_PLATFORMS and the other target's
            // entitlements. Same rule as the host below: once the scheme has
            // spoken for an identifier, only the scheme may replace it.
            let alreadyFromScheme = settingsCameFromScheme.contains(bundle) && !fromScheme
            if !alreadyFromScheme {
                if fromScheme { settingsCameFromScheme.insert(bundle) }
                info.buildSettings[bundle] = settings.compactMapValues { $0 as? String }

                // xcodebuild reports CODE_SIGN_ENTITLEMENTS relative to the project
                // directory; resolve it so the file can actually be read.
                if let relative = settings["CODE_SIGN_ENTITLEMENTS"] as? String, !relative.isEmpty {
                    let root = (projectPath as NSString).deletingLastPathComponent
                    info.entitlements[bundle] = relative.hasPrefix("/")
                        ? relative
                        : (root as NSString).appendingPathComponent(relative)
                } else if let generated = synthesizedEntitlements(forBundle: bundle, settings: settings) {
                    info.entitlements[bundle] = generated
                }
            }

            // A watchOS app is an application too: it reports ".app" exactly as
            // its host does, so wrapper alone cannot tell the two apart and the
            // watch app — always a leftover, never named by the phone app's
            // scheme — would land in `info.bundleID` simply by being read last.
            // The scheme is the tiebreak: it names the app being shipped, and
            // the leftovers are read to cover what that app embeds. So once the
            // scheme has produced a host, only the scheme may replace it.
            let isHost = wrapper == "app" || (info.bundleID.isEmpty && wrapper.isEmpty)
            if isHost, fromScheme || !hostCameFromScheme {
                hostCameFromScheme = fromScheme
                info.bundleID = bundle
                info.marketingVersion = settings["MARKETING_VERSION"] as? String ?? ""
                info.buildNumber = settings["CURRENT_PROJECT_VERSION"] as? String ?? ""
                info.team = settings["DEVELOPMENT_TEAM"] as? String ?? ""

                // Read the app target's platform from its own settings.
                //
                // SDKROOT is asked first because it resolves to the SDK this
                // scheme actually builds against — a full path ending in
                // MacOSX<version>.sdk or iPhoneOS<version>.sdk. SUPPORTED_PLATFORMS
                // only lists what the target *could* build: a multiplatform app
                // says "iphoneos iphonesimulator macosx", and treating any
                // mention of macOS as proof would ship every such app as a Mac
                // app. It stays as the fallback witness for the projects that
                // leave SDKROOT unset.
                //
                // A Mac build is then either native or Catalyst, and the two
                // need different profiles. IS_MACCATALYST is Xcode's own answer
                // to that question, resolved for this scheme, and it is the only
                // reliable one: a Catalyst target reports the macOS SDK and
                // lists "macosx" among its supported platforms exactly as a
                // native Mac app does, so without it the two are
                // indistinguishable and a Catalyst app gets a Mac App Store
                // profile that export refuses.
                let sdk = (settings["SDKROOT"] as? String ?? "").lowercased()
                let platforms = (settings["SUPPORTED_PLATFORMS"] as? String ?? "").lowercased()
                let catalyst = (settings["IS_MACCATALYST"] as? String)?.uppercased() == "YES"
                let mac: ShipPlatform = catalyst ? .macCatalyst : .macOS
                if sdk.contains("macosx") { info.platform = mac }
                else if sdk.contains("iphoneos") { info.platform = .iOS }
                else if platforms.contains("macosx") { info.platform = mac }
                else if platforms.contains("iphoneos") { info.platform = .iOS }
            } else if !info.extensionBundleIDs.contains(bundle) {
                info.extensionBundleIDs.append(bundle)
            }
        }

        // A target listed before the host app can be misfiled as an extension;
        // correct that once the host is known.
        info.extensionBundleIDs.removeAll { $0 == info.bundleID }

        // Unresolved variables are worse than blank — they look like real
        // values and fail at signing.
        if info.marketingVersion.contains("$") { info.marketingVersion = "" }
        if info.buildNumber.contains("$") { info.buildNumber = "" }

        return info
    }

    /// `-showBuildSettings -json`, decoded, for whatever selects the targets.
    private static func buildSettings(
        container: [String], selecting arguments: [String],
    ) async -> [[String: Any]] {
        let result = await Shell.run("/usr/bin/xcodebuild", container + arguments + [
            // Release: the configuration that actually ships, and the one whose
            // version numbers matter.
            "-configuration", "Release",
            "-showBuildSettings", "-json",
        ])
        return firstJSON(in: result.output, opening: "[") as? [[String: Any]] ?? []
    }

    /// Settings for the project's targets that the scheme never reported.
    ///
    /// A scheme answers for the targets its build action names, and that need
    /// not be all of them. An app extension is usually embedded through a copy
    /// phase and built as an *implicit dependency*, so a Safari extension, a
    /// widget or a share extension can be absent from the scheme's answer while
    /// very much being inside the shipped app.
    ///
    /// Absent here meant absent from `entitlements`, and an extension whose
    /// entitlements are unknown gets signed with only the identifiers codesign
    /// takes from the profile: App Sandbox and the app group are dropped. Apple
    /// does not catch it, because the *app* is sandboxed and the app is what
    /// validation looks at. It surfaces at runtime instead, as an extension that
    /// loads and then cannot reach anything it shares with its container.
    ///
    /// Asked per target, and only for targets the scheme did not cover, so the
    /// usual project — whose scheme does name everything — adds nothing beyond
    /// one cheap read of `project.pbxproj`.
    private static func settingsForTargetsMissing(
        from entries: [[String: Any]], projectPath: String,
    ) async -> [[String: Any]] {
        let covered = Set(entries.compactMap { $0["target"] as? String })
        let missing = await projectTargets(projectPath: projectPath)
            .filter { !covered.contains($0) }
        guard !missing.isEmpty else { return [] }

        // Concurrently, because each call is a whole `xcodebuild` that resolves
        // the package graph again — eight seconds on a project with a dozen SPM
        // dependencies — and an app with a widget, a share extension and a
        // notification extension would otherwise pay that three times in a row.
        return await withTaskGroup(of: (offset: Int, entries: [[String: Any]]).self) { group in
            for (offset, target) in missing.enumerated() {
                group.addTask {
                    // `-target` is a project-level selector and is not valid
                    // against a workspace, so address the `.xcodeproj` directly
                    // even where one exists. A target that cannot be resolved
                    // that way — a Pods target needing the workspace, say —
                    // simply yields nothing, and the caller already skips the
                    // CocoaPods and framework ids anyway.
                    (offset, await buildSettings(
                        container: ["-project", projectPath],
                        selecting: ["-target", target]))
                }
            }

            // Restored to the order the targets were asked in, rather than the
            // order the calls happened to finish: `extensionBundleIDs` is built
            // from this and reordering it every run would make detection look
            // unstable to anyone watching it.
            var collected: [(offset: Int, entries: [[String: Any]])] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.offset < $1.offset }.flatMap(\.entries)
        }
    }

    /// The names of the targets belonging to the `.xcodeproj` itself.
    ///
    /// Read straight out of `project.pbxproj`, which is an OpenStep property
    /// list that Foundation parses natively. `xcodebuild -list` answers the
    /// same question authoritatively, but it resolves the package graph first
    /// and costs about nine seconds on a project with a dozen SPM dependencies
    /// — for a list of names that is sitting in a file. It stays as the
    /// fallback, so an unreadable or reformatted `.pbxproj` costs speed rather
    /// than correctness.
    ///
    /// Names taken this way are only *candidates*: each is handed to
    /// `-showBuildSettings -target`, which resolves it properly or reports
    /// nothing, so a stale name here cannot put wrong settings into `Info`.
    /// `PBXNativeTarget` is the filter because aggregate and legacy targets
    /// build no bundle, and a CocoaPods workspace keeps its own targets in a
    /// separate `Pods.xcodeproj` that this never reads.
    ///
    /// The fallback asks the project directly rather than through
    /// `container(forProjectPath:)`: `list` answers through the workspace
    /// wherever there is one, and a workspace carries no targets of its own.
    private static func projectTargets(projectPath: String) async -> [String] {
        let pbxproj = (projectPath as NSString).appendingPathComponent("project.pbxproj")
        if let data = FileManager.default.contents(atPath: pbxproj),
           let plist = try? PropertyListSerialization.propertyList(
               from: data, options: [], format: nil) as? [String: Any],
           let objects = plist["objects"] as? [String: Any] {
            let names = objects.values.compactMap { $0 as? [String: Any] }
                .filter { $0["isa"] as? String == "PBXNativeTarget" }
                .compactMap { $0["name"] as? String }
            if !names.isEmpty { return names }
        }

        let result = await Shell.run(
            "/usr/bin/xcodebuild", ["-project", projectPath, "-list", "-json"])
        guard let json = firstJSON(in: result.output, opening: "{") as? [String: Any],
              let project = json["project"] as? [String: Any]
        else { return [] }
        return project["targets"] as? [String] ?? []
    }

    /// The entitlements Xcode would generate, written out as a file.
    ///
    /// A modern Mac target usually declares no `.entitlements` file at all: the
    /// sandbox and each permission inside it are *build settings*, and Xcode
    /// turns them into entitlements while signing. This tool archives unsigned
    /// and signs afterwards, so that step never runs — the shipped app carries
    /// none of them, and App Store Connect refuses the upload outright ("App
    /// sandbox not enabled"), after a full build.
    ///
    /// Writing the same file Xcode would have written puts the project's own
    /// declared permissions back where signing can find them. Nothing is
    /// invented: every key below is one the project asked for, and a target
    /// that never opted into the sandbox gets no file at all.
    private static func synthesizedEntitlements(
        forBundle bundle: String, settings: [String: Any],
    ) -> String? {
        func enabled(_ setting: String) -> Bool {
            (settings[setting] as? String)?.uppercased() == "YES"
        }

        // The sandbox is the gate. Every other key is a permission *within* it,
        // and Xcode emits none of them for an unsandboxed target.
        guard enabled("ENABLE_APP_SANDBOX") else { return nil }
        var entitlements: [String: Any] = ["com.apple.security.app-sandbox": true]

        for (setting, key) in [
            "ENABLE_INCOMING_NETWORK_CONNECTIONS": "com.apple.security.network.server",
            "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "com.apple.security.network.client",
            "ENABLE_RESOURCE_ACCESS_AUDIO_INPUT": "com.apple.security.device.audio-input",
            "ENABLE_RESOURCE_ACCESS_BLUETOOTH": "com.apple.security.device.bluetooth",
            "ENABLE_RESOURCE_ACCESS_CALENDARS": "com.apple.security.personal-information.calendars",
            "ENABLE_RESOURCE_ACCESS_CAMERA": "com.apple.security.device.camera",
            "ENABLE_RESOURCE_ACCESS_CONTACTS": "com.apple.security.personal-information.addressbook",
            "ENABLE_RESOURCE_ACCESS_LOCATION": "com.apple.security.personal-information.location",
            "ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY":
                "com.apple.security.personal-information.photos-library",
            "ENABLE_RESOURCE_ACCESS_PRINTING": "com.apple.security.print",
            "ENABLE_RESOURCE_ACCESS_USB": "com.apple.security.device.usb",
        ] where enabled(setting) {
            entitlements[key] = true
        }

        // File access is three-valued — off, read-only or read/write — and the
        // level picks the *key*, not the value.
        for (setting, prefix) in [
            "ENABLE_USER_SELECTED_FILES": "com.apple.security.files.user-selected",
            "ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER": "com.apple.security.files.downloads",
            "ENABLE_FILE_ACCESS_PICTURE_FOLDER": "com.apple.security.assets.pictures",
            "ENABLE_FILE_ACCESS_MUSIC_FOLDER": "com.apple.security.assets.music",
            "ENABLE_FILE_ACCESS_MOVIES_FOLDER": "com.apple.security.assets.movies",
        ] {
            switch (settings[setting] as? String)?.lowercased() {
            case "readonly": entitlements["\(prefix).read-only"] = true
            case "readwrite": entitlements["\(prefix).read-write"] = true
            default: break
            }
        }

        // Kept outside the build directory, which every run deletes before
        // archiving — signing reads this file long after that point.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MailBoxShip/GeneratedEntitlements", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(bundle).entitlements")
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: entitlements, format: .xml, options: 0),
            (try? data.write(to: file)) != nil
        else { return nil }
        return file.path
    }

    /// Entitlements file per bundle id, gathered across *every* scheme.
    ///
    /// A companion watch app has its own scheme and is invisible to the parent
    /// app's build settings, so its entitlements — and therefore the App Store
    /// capabilities its App ID needs — only surface by inspecting each scheme.
    /// Used when the archive turns up a bundle id preparation never saw.
    static func entitlementsAcrossSchemes(projectPath: String) async -> [String: String] {
        let (schemes, _) = await list(projectPath: projectPath)
        var map: [String: String] = [:]
        for scheme in schemes {
            for (bundle, path) in await inspect(projectPath: projectPath, scheme: scheme).entitlements
            where map[bundle] == nil {
                map[bundle] = path
            }
        }
        return map
    }

    // MARK: - Reading xcodebuild's JSON

    /// The first complete JSON document in xcodebuild's output.
    ///
    /// stdout and stderr arrive on one pipe, and xcodebuild writes plenty to
    /// stderr that is not JSON. Adding `-scheme` reliably produces a
    /// destination warning whose body is a list of `{ platform:macOS, … }`
    /// lines — so slicing from the first `{` or `[` starts inside that warning,
    /// the parse fails, and every detected value comes back empty with nothing
    /// in the log to say why. A candidate therefore has to be both at the start
    /// of a line *and* parse, because the warning's braces sit at column zero
    /// too.
    private static func firstJSON(in output: String, opening: Character) -> Any? {
        let closing: Character = opening == "[" ? "]" : "}"
        let characters = Array(output)
        var index = 0

        while index < characters.count {
            guard characters[index] == opening,
                  index == 0 || characters[index - 1] == "\n"
            else {
                index += 1
                continue
            }
            if let end = closingIndex(from: index, in: characters,
                                      opening: opening, closing: closing),
               let data = String(characters[index...end]).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                return json
            }
            index += 1
        }
        return nil
    }

    /// Index of the bracket closing the one at `start`, ignoring brackets
    /// inside string literals — build settings are full of them.
    private static func closingIndex(
        from start: Int, in characters: [Character],
        opening: Character, closing: Character,
    ) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false

        for index in start..<characters.count {
            let character = characters[index]
            if escaped { escaped = false; continue }
            if inString {
                if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true }
            else if character == opening { depth += 1 }
            else if character == closing {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }
}
