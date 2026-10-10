import AppKit
import Foundation
import SwiftUI

/// Every run in the window, one `Runner` per profile, several at once.
///
/// A run used to be the window's: one `Runner`, and the profile list locked
/// while it worked, so three apps meant three archives back to back with
/// nothing to do in between. Each profile now has a runner of its own and they
/// run side by side — switch to another app while one archives and start that
/// one too. Past `limit` a start waits its turn rather than being refused, and
/// begins the moment a slot frees.
///
/// What cannot be shared is handled below this level, not here: each run gets
/// its own scratch folder, signing is taken one run at a time, and minting a
/// certificate one run per account (see `Pipeline`).
@MainActor
final class RunCenter: ObservableObject {

    /// How many apps may build at once. Archives are CPU- and memory-heavy;
    /// past three or four on one Mac they mostly slow each other down.
    @Published var limit: Int {
        didSet {
            let clamped = min(max(limit, Self.limits.lowerBound), Self.limits.upperBound)
            if clamped != limit { limit = clamped; return }
            UserDefaults.standard.set(limit, forKey: Self.limitKey)
            startQueued()
        }
    }

    static let limits = 1...6
    private static let limitKey = "parallelRunLimit"

    /// Profiles with a run in flight, and those waiting for a slot. Published
    /// so counts and the Ship Many sheet follow along without each one having
    /// to observe every runner.
    @Published private(set) var running: Set<UUID> = []
    @Published private(set) var queued: [UUID] = []

    /// Every profile started this session, most recent first — what the
    /// Activity list shows. Finished runs stay until cleared, so a result
    /// that landed while another app was on screen is still there to find.
    @Published private(set) var recent: [UUID] = []

    /// Not published: created lazily while views are being built, and a
    /// published write from inside a view update is a runtime fault.
    private var runners: [UUID: Runner] = [:]
    private var starts: [UUID: () -> Void] = [:]

    /// Stands in for "no profile selected", so a view always has a runner.
    private let idle = Runner()

    init() {
        let saved = UserDefaults.standard.integer(forKey: Self.limitKey)
        limit = saved == 0 ? 3 : min(max(saved, Self.limits.lowerBound), Self.limits.upperBound)
    }

    func runner(for id: UUID?) -> Runner {
        guard let id else { return idle }
        if let existing = runners[id] { return existing }
        let runner = Runner()
        runner.onStateChange = { [weak self] in self?.refresh() }
        runners[id] = runner
        return runner
    }

    /// The runner of a profile that has run, or has a run waiting, this
    /// session — for list rows, which have nothing to show for one that has
    /// not and should not make a runner just to find that out.
    func activity(for id: UUID) -> Runner? {
        guard let runner = runners[id], runner.isBusy || runner.finished else { return nil }
        return runner
    }

    func isBusy(_ id: UUID) -> Bool { running.contains(id) || queued.contains(id) }

    var busyCount: Int { running.count + queued.count }

    /// Start a run for `id` now, or queue it behind the ones already going.
    ///
    /// `onIdentityCreated` is attached to *this* profile's runner, so a signing
    /// identity made by a run in the background is stored against the profile
    /// that made it — not whichever one is on screen when it lands.
    func submit(
        _ id: UUID, upload: Bool, revealWhenBuilt: Bool = true,
        onIdentityCreated: @escaping (String) -> Void,
        input: @escaping @MainActor (_ log: @escaping @Sendable (String) -> Void) async throws -> Pipeline.Input,
    ) {
        let runner = runner(for: id)
        guard !runner.isBusy else { return }
        runner.onIdentityCreated = onIdentityCreated
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)

        let start: () -> Void = { [weak runner] in
            runner?.run(upload: upload, revealWhenBuilt: revealWhenBuilt, input: input)
        }
        if running.count < limit {
            start()
        } else {
            starts[id] = start
            queued.append(id)
            runner.markQueued(upload: upload)
        }
    }

    /// Take a waiting run back out of the queue. A run already going is left
    /// alone: stopping `xcodebuild` or `altool` part way leaves an account
    /// half set up, or a build number spent on nothing.
    func cancelQueued(_ id: UUID) {
        guard let index = queued.firstIndex(of: id) else { return }
        queued.remove(at: index)
        starts[id] = nil
        runners[id]?.unqueue()
    }

    /// Take finished runs off the Activity list. Their results stay with
    /// their profiles — the log, the build, the badge in the list — so this
    /// tidies the list without losing anything.
    func clearFinished() {
        recent.removeAll { !(runners[$0]?.isBusy ?? false) }
    }

    var hasFinished: Bool {
        recent.contains { !(runners[$0]?.isBusy ?? false) }
    }

    /// Drop the runner of a deleted profile, unless it is still working.
    func forget(_ id: UUID) {
        guard let runner = runners[id], !runner.isBusy else { return }
        runners[id] = nil
        recent.removeAll { $0 == id }
    }

    /// Set while queued runs are being started. Starting one reports back
    /// through `refresh`, which would otherwise start the next from inside
    /// this loop.
    private var starting = false

    private func refresh() {
        let now = Set(runners.filter { $0.value.isRunning }.map(\.key))
        // A run ending while another app has focus — which, with several
        // going, is most of them — gets the Dock icon's attention once.
        if !running.subtracting(now).isEmpty, !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
        if now != running {
            running = now
        } else {
            // A run that failed before it started — a profile not ready — or
            // one taken out of the queue changes no count, but its row still
            // has a status to show or drop.
            objectWillChange.send()
        }
        startQueued()
        // How many apps are building or waiting, on the Dock icon — visible
        // with the window closed or behind everything else.
        NSApp.dockTile.badgeLabel = busyCount > 0 ? "\(busyCount)" : nil
    }

    private func startQueued() {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        while running.count < limit, !queued.isEmpty {
            let id = queued.removeFirst()
            guard let start = starts.removeValue(forKey: id) else { continue }
            // `refresh` counts it as running once it has actually started.
            start()
        }
    }
}

/// Reading a profile's project without a screen, and turning it into the
/// pipeline's input.
///
/// The two screens detect as you look at a profile, and start a run from what
/// they found. A run nobody is looking at — one of several from Ship Many, or
/// the CLI's — has to do that reading itself. Same rules either way: the saved
/// scheme while it still exists, the pinned platform before what the scheme
/// reports, and the sibling scheme when the pinned platform is one the saved
/// scheme cannot build.
enum RunPlan {

    struct Resolved {
        var input: Pipeline.Input
        /// The profile as the project now describes it — scheme, identifiers
        /// and detected platform — for the caller to save back.
        var profile: ShipProfile
    }

    @MainActor
    static func resolve(
        _ original: ShipProfile, configuration: Pipeline.Configuration,
        log: (String) -> Void = { _ in },
    ) async -> Resolved {
        var profile = original
        if let resolved = ProjectInspector.resolveProject(at: profile.projectPath) {
            profile.projectPath = resolved
        }
        let path = profile.projectPath

        log("→ Reading \((path as NSString).lastPathComponent)…\n")
        let (schemes, _) = await ProjectInspector.list(projectPath: path)
        let scheme = schemes.contains(profile.scheme) ? profile.scheme : (schemes.first ?? profile.scheme)
        var info = await ProjectInspector.inspect(projectPath: path, scheme: scheme)
        info.schemes = schemes
        profile.scheme = scheme
        if let platform = info.platform { profile.detectedPlatform = platform }

        if let pinned = profile.platformOverride, info.platform != nil,
           info.platform != pinned, info.canBuild(pinned) != true,
           let sibling = await ProjectInspector.scheme(
               building: info.bundleID, for: pinned, among: schemes,
               excluding: scheme, projectPath: path) {
            log("  Scheme \(scheme) builds for \(info.platform?.displayName ?? "another platform"); "
                + "using \(sibling.scheme) for \(pinned.displayName)\n")
            profile.scheme = sibling.scheme
            info = sibling.info
            info.schemes = schemes
            profile.detectedPlatform = pinned
            profile.bundleID = info.bundleID
            profile.extensionBundleIDsRaw = info.extensionBundleIDs(shippingAs: pinned)
                .joined(separator: ", ")
        }

        let platform = profile.shipPlatform(detected: info.platform)

        // Blanks only. A typed identifier is a decision, and preflight is
        // what compares it with the project — and says so — before anything
        // is created on the account.
        if profile.bundleID.isEmpty { profile.bundleID = info.bundleID }
        let embedded = info.extensionBundleIDs(shippingAs: platform)
        if profile.extensionBundleIDsRaw.isEmpty, !embedded.isEmpty {
            profile.extensionBundleIDsRaw = embedded.joined(separator: ", ")
        }
        log("  \(profile.scheme) · \(platform.displayName)"
            + (info.summary.isEmpty ? "" : " · \(info.summary)") + "\n")

        return Resolved(
            input: Pipeline.Input(
                profile: profile, configuration: configuration,
                platform: platform, entitlementsByBundleID: info.entitlements),
            profile: profile)
    }
}

extension ProfileStore {
    /// Save what a headless read learned about a profile's project, without
    /// touching anything the person may have edited meanwhile.
    func adoptResolved(_ resolved: ShipProfile) {
        update(resolved.id) { profile in
            profile.projectPath = resolved.projectPath
            profile.scheme = resolved.scheme
            profile.detectedPlatformRaw = resolved.detectedPlatformRaw
            // `RunPlan` changes these only to fill a blank or to follow a
            // sibling scheme — both of which the screens would also save.
            profile.bundleID = resolved.bundleID
            profile.extensionBundleIDsRaw = resolved.extensionBundleIDsRaw
        }
    }
}
