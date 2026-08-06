import Foundation

/// The platform a scheme builds for.
///
/// Everything the pipeline does that differs between an iPhone app and a Mac
/// app keys off this: the archive destination, the App Store profile type, the
/// App ID platform, whether export produces a `.pkg` needing an installer
/// certificate, and the `altool` platform on validate and upload.
enum ShipPlatform: String, Sendable {
    case iOS
    case macOS
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
        /// What the app target builds for. Drives the whole macOS-vs-iOS split
        /// downstream; defaults to iOS, so a project that cannot be read keeps
        /// the original behaviour.
        var platform: ShipPlatform = .iOS
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
    /// `-showBuildSettings` returns one entry per target in the scheme, which
    /// is what makes the extension bundle ids discoverable — they are simply
    /// the non-application targets. Parsing the `.pbxproj` by hand would find
    /// the same strings but could not tell which target they belonged to, nor
    /// resolve `$(...)` variables.
    static func inspect(projectPath: String, scheme: String) async -> Info {
        var info = Info()

        let result = await Shell.run("/usr/bin/xcodebuild",
            container(forProjectPath: projectPath).arguments + [
            "-scheme", scheme,
            // Release: the configuration that actually ships, and the one whose
            // version numbers matter.
            "-configuration", "Release",
            "-showBuildSettings", "-json",
        ])

        guard let entries = firstJSON(in: result.output, opening: "[") as? [[String: Any]]
        else { return info }

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

            info.buildSettings[bundle] = settings.compactMapValues { $0 as? String }

            // xcodebuild reports CODE_SIGN_ENTITLEMENTS relative to the project
            // directory; resolve it so the file can actually be read.
            if let relative = settings["CODE_SIGN_ENTITLEMENTS"] as? String, !relative.isEmpty {
                let root = (projectPath as NSString).deletingLastPathComponent
                info.entitlements[bundle] = relative.hasPrefix("/")
                    ? relative
                    : (root as NSString).appendingPathComponent(relative)
            }

            if wrapper == "app" || (info.bundleID.isEmpty && wrapper.isEmpty) {
                info.bundleID = bundle
                info.marketingVersion = settings["MARKETING_VERSION"] as? String ?? ""
                info.buildNumber = settings["CURRENT_PROJECT_VERSION"] as? String ?? ""
                info.team = settings["DEVELOPMENT_TEAM"] as? String ?? ""

                // Read the app target's platform from its own settings.
                // SUPPORTED_PLATFORMS is "macosx" for a Mac app and
                // "iphoneos iphonesimulator" for an iPhone app; SDKROOT is a
                // second witness for either.
                let platforms = (settings["SUPPORTED_PLATFORMS"] as? String ?? "").lowercased()
                let sdk = (settings["SDKROOT"] as? String ?? "").lowercased()
                info.platform = (platforms.contains("macos") || sdk.contains("macos"))
                    ? .macOS : .iOS
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
