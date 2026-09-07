import AppKit
import Foundation

/// What a profile's project actually builds: the app's own icon and the name a
/// user sees under it.
///
/// Both are read off disk — the asset catalog and the project file — never from
/// the App Store. Most of what this tool points at has either never shipped or
/// is sitting in Prepare for Submission, and a store lookup answers "nothing"
/// for every one of those.
struct AppIdentity {
    var icon: NSImage?
    var displayName: String?
}

/// The filesystem half. Deliberately free of AppKit and of any main-actor
/// state so it can run on a background task: it hands back a file URL and a
/// string, and the caller turns those into an image.
enum AppIdentityReader {

    struct Found: Sendable {
        var iconURL: URL?
        var displayName: String?
    }

    /// Directories that cannot hold the app's own icon or name and are big
    /// enough that walking them is the difference between a few milliseconds
    /// and several seconds.
    private static let skippedDirectories: Set<String> = [
        ".build", "build", "DerivedData", "Pods", "Carthage", "node_modules",
        ".swiftpm", "fastlane", "Frameworks", "vendor",
    ]

    /// Bundles that are directories. Descending into one finds a *built* copy
    /// of some app's icon, which is not the same thing as the project's.
    private static let skippedExtensions: Set<String> = [
        "xcodeproj", "xcworkspace", "app", "framework", "bundle", "appex", "playground",
    ]

    /// A tree this size is a checkout gone wrong, not a project. Stop rather
    /// than let one bad path hold a background task open indefinitely.
    private static let scanLimit = 20_000

    /// `bundleID` is what makes this exact rather than a guess. A project file
    /// holds one settings block per target per configuration, and a widget's
    /// block looks exactly like the app's — `dime.xcodeproj` answers
    /// "BudgetIntent" to anything that just takes the first match, when the app
    /// is called "Receipt Scanner & Expense Plan". The profile already knows
    /// which identifier it ships, so the app's own block can be picked out.
    static func read(projectPath: String, bundleID: String = "") -> Found {
        guard !projectPath.isEmpty,
              FileManager.default.fileExists(atPath: projectPath)
        else { return Found() }

        let root = (projectPath as NSString).deletingLastPathComponent
        let scan = scan(root: root)
        let pbxproj = (projectPath as NSString).appendingPathComponent("project.pbxproj")
        let project = try? String(contentsOfFile: pbxproj, encoding: .utf8)
        let target = project.flatMap { appSettings(in: $0, bundleID: bundleID) }

        return Found(
            iconURL: appIcon(among: scan.iconSets, named: target.flatMap {
                buildSetting("ASSETCATALOG_COMPILER_APPICON_NAME", in: $0)
            }),
            displayName: displayName(
                projectPath: projectPath, root: root, target: target, plists: scan.infoPlists),
        )
    }

    // MARK: - Finding the app target

    /// The build-settings block belonging to the app, as raw project-file text.
    ///
    /// Matched on the identifier the profile ships. Without one (a profile whose
    /// project has never been read) the app is taken to be the target with the
    /// shortest identifier: an extension's is always the app's with a suffix.
    private static func appSettings(in pbxproj: String, bundleID: String) -> String? {
        let blocks = settingsBlocks(in: pbxproj)
        guard !blocks.isEmpty else { return nil }

        if !bundleID.isEmpty,
           let hit = blocks.first(where: { $0.bundleID == bundleID }) {
            return hit.text
        }
        return blocks
            .filter { !$0.bundleID.isEmpty }
            .min { a, b in
                let (ca, cb) = (a.bundleID.split(separator: ".").count, b.bundleID.split(separator: ".").count)
                if ca != cb { return ca < cb }
                return a.bundleID < b.bundleID
            }?.text
    }

    private struct SettingsBlock {
        var bundleID: String
        var text: String
    }

    /// Every `buildSettings = { … }` in the project file, paired with the
    /// identifier it configures. Brace counting, because a settings block
    /// nests dictionaries and the first `};` is not the end of it.
    private static func settingsBlocks(in pbxproj: String) -> [SettingsBlock] {
        var out: [SettingsBlock] = []
        var search = pbxproj[...]
        while let start = search.range(of: "buildSettings = {") {
            var depth = 1
            var index = start.upperBound
            while index < search.endIndex, depth > 0 {
                if search[index] == "{" { depth += 1 }
                if search[index] == "}" { depth -= 1 }
                index = search.index(after: index)
            }
            let text = String(search[start.upperBound..<index])
            out.append(SettingsBlock(
                bundleID: buildSetting("PRODUCT_BUNDLE_IDENTIFIER", in: text) ?? "", text: text))
            search = search[index...]
        }
        return out
    }

    // MARK: - Walking the project

    private struct Scan {
        var iconSets: [URL] = []
        var infoPlists: [URL] = []
    }

    private static func scan(root: String) -> Scan {
        var out = Scan()
        guard !root.isEmpty else { return out }
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        )
        guard let enumerator else { return out }

        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            if seen > scanLimit { break }

            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = url.lastPathComponent

            guard isDirectory else {
                if name == "Info.plist" { out.infoPlists.append(url) }
                continue
            }
            if skippedDirectories.contains(name)
                || skippedExtensions.contains(url.pathExtension.lowercased()) {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "appiconset" {
                out.iconSets.append(url)
                enumerator.skipDescendants()
            }
        }
        return out
    }

    // MARK: - Icon

    /// The best icon set in the project, then the biggest image inside it.
    ///
    /// A project routinely carries several: the app's, a widget's, an alternate
    /// icon, a `AppIcon-Beta`. The one named exactly `AppIcon` wins, and among
    /// equals the shallowest path does — an extension's assets always sit
    /// deeper than the app's.
    private static func appIcon(among sets: [URL], named preferred: String?) -> URL? {
        let wanted = preferred ?? "AppIcon"
        let ranked = sets.sorted { a, b in
            let aWanted = a.deletingPathExtension().lastPathComponent == wanted
            let bWanted = b.deletingPathExtension().lastPathComponent == wanted
            if aWanted != bWanted { return aWanted }
            if a.pathComponents.count != b.pathComponents.count {
                return a.pathComponents.count < b.pathComponents.count
            }
            return a.path < b.path
        }
        for set in ranked {
            if let image = largestImage(in: set) { return image }
        }
        return nil
    }

    /// Biggest file in the set. An `.appiconset` holds the same artwork at a
    /// dozen sizes and the 1024pt marketing icon is always the largest of them,
    /// so file size picks it without parsing Contents.json.
    private static func largestImage(in set: URL) -> URL? {
        let keys: [URLResourceKey] = [.fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: set, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let images = files.filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }
        return images.max { byteSize(of: $0) < byteSize(of: $1) }
    }

    private static func byteSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    // MARK: - Name

    /// The name that appears under the icon, in the order Apple resolves it.
    ///
    /// Modern projects have no Info.plist at all — the keys live in the project
    /// file as `INFOPLIST_KEY_*` — so that is asked first, and the plists are
    /// the fallback for projects that still ship one.
    private static func displayName(
        projectPath: String, root: String, target: String?, plists: [URL],
    ) -> String? {
        // Modern projects have no Info.plist at all — these keys are the file.
        if let target, let name = buildSetting("INFOPLIST_KEY_CFBundleDisplayName", in: target) {
            return name
        }
        // Otherwise the plist the app target actually points at, then the ranked
        // sweep for the projects whose INFOPLIST_FILE we could not resolve.
        var candidates: [URL] = []
        if let target, let relative = buildSetting("INFOPLIST_FILE", in: target),
           relative.hasSuffix(".plist") {
            candidates.append(URL(fileURLWithPath: relative.hasPrefix("/")
                ? relative
                : (root as NSString).appendingPathComponent(relative)))
        }
        candidates += rankedPlists(plists, projectPath: projectPath)

        for plist in candidates {
            guard let data = try? Data(contentsOf: plist),
                  let dictionary = try? PropertyListSerialization.propertyList(
                    from: data, format: nil) as? [String: Any]
            else { continue }
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let raw = dictionary[key] as? String, let name = literal(raw) { return name }
            }
        }
        if let target {
            // CFBundleName in a plist is very often just `$(PRODUCT_NAME)`, and
            // the setting behind it is a real name: EPSCON.xcodeproj builds
            // "Printer". `$(TARGET_NAME)` ones fall out in `literal`.
            for key in ["INFOPLIST_KEY_CFBundleName", "PRODUCT_NAME"] {
                if let name = buildSetting(key, in: target) { return name }
            }
        }
        return nil
    }

    /// Info.plists, app's first.
    ///
    /// A project with a widget and two intents extensions has four of them at
    /// the same depth, so depth alone is a coin toss — `dime.xcodeproj` answered
    /// "BudgetIntent" that way. The folder Xcode names after the project is the
    /// app's, and that breaks the tie. Test bundles never qualify: their name is
    /// the app's with "Tests" on the end.
    private static func rankedPlists(_ plists: [URL], projectPath: String) -> [URL] {
        let base = ((projectPath as NSString).lastPathComponent as NSString).deletingPathExtension
        func isAppFolder(_ url: URL) -> Bool {
            url.deletingLastPathComponent().lastPathComponent
                .caseInsensitiveCompare(base) == .orderedSame
        }
        return plists
            .filter { !$0.path.contains("Tests") }
            .sorted { a, b in
                if isAppFolder(a) != isAppFolder(b) { return isAppFolder(a) }
                if a.pathComponents.count != b.pathComponents.count {
                    return a.pathComponents.count < b.pathComponents.count
                }
                return a.path < b.path
            }
    }

    /// First literal value of `key` in a project file, across its Debug and
    /// Release blocks. Quotes are Xcode's, not part of the name.
    private static func buildSetting(_ key: String, in pbxproj: String) -> String? {
        var search = pbxproj[...]
        while let range = search.range(of: "\(key) = ") {
            let rest = search[range.upperBound...]
            guard let end = rest.firstIndex(of: ";") else { break }
            var value = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            if let name = literal(value) { return name }
            search = rest[end...]
        }
        return nil
    }

    /// A build setting is only a name if it is spelled out. `$(PRODUCT_NAME)`
    /// and `${TARGET_NAME}` name nothing anyone would recognise in a list.
    private static func literal(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$("), !trimmed.contains("${") else { return nil }
        return trimmed
    }
}

/// One decoded identity per project path, for the whole window.
///
/// The read is a directory walk and a 1024pt PNG; doing it per row per redraw
/// would be visible. Rows ask for what is already here and start a load if it
/// is missing, so the list draws immediately and fills in.
@MainActor
final class AppIdentityStore: ObservableObject {

    @Published private(set) var byProject: [String: AppIdentity] = [:]
    private var loading: Set<String> = []

    func identity(for profile: ShipProfile) -> AppIdentity? {
        byProject[Self.key(profile)]
    }

    /// Load and cache, returning what was found. Concurrent callers for the
    /// same project get nil rather than a second walk of the same tree.
    @discardableResult
    func load(_ profile: ShipProfile) async -> AppIdentity? {
        let path = profile.projectPath
        guard !path.isEmpty else { return nil }
        let key = Self.key(profile)
        if let cached = byProject[key] { return cached }
        guard !loading.contains(key) else { return nil }

        loading.insert(key)
        let bundleID = profile.bundleID
        let found = await Task.detached(priority: .utility) {
            AppIdentityReader.read(projectPath: path, bundleID: bundleID)
        }.value
        loading.remove(key)

        let identity = AppIdentity(
            icon: found.iconURL.flatMap { NSImage(contentsOf: $0) },
            displayName: found.displayName,
        )
        byProject[key] = identity
        return identity
    }

    /// Drop what we know, so a changed icon or name is read again rather than
    /// served from this window's copy.
    func forget(_ profile: ShipProfile) {
        let key = Self.key(profile)
        byProject[key] = nil
        loading.remove(key)
    }

    /// Two profiles can share a project and ship different identifiers — the
    /// app and one of its extensions — and they do not resolve to the same
    /// icon or name, so both belong in the key.
    private static func key(_ profile: ShipProfile) -> String {
        "\(profile.projectPath)\u{1}\(profile.bundleID)"
    }
}
