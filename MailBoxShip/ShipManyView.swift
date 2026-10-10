import SwiftUI

// MARK: - Run status beside a profile

/// Where a profile's run stands, small enough to sit at the end of a list row.
///
/// Runs carry on while another profile is on screen, so the list itself has to
/// say which apps are building — otherwise the only way to know is to click
/// through them one by one.
struct RunBadge: View {
    @ObservedObject var runner: Runner
    /// Adds the stage or outcome in words; the bare icon carries it as a
    /// tooltip instead.
    var showsLabel = false

    var body: some View {
        if let state {
            HStack(spacing: 4) {
                Group {
                    if state.spinning {
                        InlineSpinner(size: 10)
                    } else {
                        Image(systemName: state.symbol)
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .foregroundStyle(state.tint)
                if showsLabel {
                    Text(state.label)
                        .font(Design.Face.caption)
                        .foregroundStyle(state.tint == .secondary ? Color.secondary : state.tint)
                        .lineLimit(1)
                }
            }
            .help(runner.status)
        }
    }

    private var state: (symbol: String, tint: Color, label: String, spinning: Bool)? {
        if runner.isQueued { return ("clock", .secondary, "Queued", false) }
        if runner.isRunning {
            return ("", Design.accentSolid, runner.currentStage?.title ?? "Reading project", true)
        }
        guard runner.finished else { return nil }
        if runner.failed { return ("xmark.circle.fill", Design.failure, "Failed", false) }
        return ("checkmark.circle.fill", Design.success,
                runner.result?.uploaded == true ? "Uploaded" : "Built", false)
    }
}

/// The platform a profile ships as, as a glyph — what tells "CriFly" and
/// "CriFly · macOS" apart at a glance in a list of icons that are otherwise
/// the same.
struct PlatformMark: View {
    let platform: ShipPlatform?

    var body: some View {
        if let platform {
            Image(systemName: platform.symbol)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .help(platform.displayName)
        }
    }
}

/// A thin bar for how far a run has got — readable in a list where a full
/// stage strip per row would be far too much.
struct ThinProgress: View {
    let value: Double
    var tint: Color = Design.accentSolid

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: max(4, geometry.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 3)
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

// MARK: - Versions

/// An app's platform versions as tabs — each one its own profile — with the
/// missing platforms one click away.
///
/// "Ship the Mac version too" used to mean finding the right profile in a long
/// list, or knowing that a version could be made at all. Here the versions of
/// the app on screen sit side by side under its name, switching is one click,
/// and the "+" says plainly which platforms it does not have yet.
struct VersionTabs: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var runs: RunCenter
    /// The platform the profile on screen ships as, from live detection —
    /// which the other tabs, read from saved profiles, cannot have.
    let currentPlatform: ShipPlatform
    var canAdd = true
    let add: (ShipPlatform) -> Void

    var body: some View {
        let family = store.family(of: store.current)
        let platforms = family.map { platform(of: $0) }
        let missing = ShipPlatform.allCases.filter { !platforms.contains($0) }

        HStack(spacing: 6) {
            ForEach(family) { profile in
                let platform = platform(of: profile)
                // Two versions on one platform — a duplicate — are told apart by name.
                let shared = platforms.filter { $0 == platform }.count > 1
                VersionTab(
                    title: platform.map { shared ? profile.name : $0.displayName } ?? profile.name,
                    symbol: platform?.symbol ?? "questionmark.app",
                    selected: profile.id == store.selectedID,
                    activity: runs.activity(for: profile.id),
                ) {
                    store.selectedID = profile.id
                }
                .help(profile.name)
            }

            if !missing.isEmpty {
                Menu {
                    ForEach(missing) { platform in
                        Button {
                            add(platform)
                        } label: {
                            Label("Add \(platform.displayName) version", systemImage: platform.symbol)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 9.5, weight: .bold))
                        Text(family.count == 1 ? "Add platform" : "Add").font(Design.Face.label)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!canAdd)
                .help("Make another profile that ships this app for "
                      + missing.map(\.displayName).joined(separator: " or ")
                      + " — its own scheme and build numbers, shippable alongside this one.")
            }
        }
    }

    private func platform(of profile: ShipProfile) -> ShipPlatform? {
        profile.id == store.current.id ? currentPlatform : profile.knownPlatform
    }
}

private struct VersionTab: View {
    let title: String
    let symbol: String
    let selected: Bool
    let activity: Runner?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                Text(title).font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                if let activity { RunBadge(runner: activity) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(selected
                               ? Design.accentSolid.opacity(0.14)
                               : Color.primary.opacity(hovering ? 0.08 : 0.04)),
            )
            .overlay(
                Capsule().strokeBorder(selected ? Design.accentSolid.opacity(0.45) : Design.hairline,
                                       lineWidth: 1),
            )
            .foregroundStyle(selected ? Design.accentSolid : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Activity

/// Every app started this session, with where each one has got to.
///
/// With several apps building, the one on screen is rarely the one that just
/// finished. This is the single place to see them all: stage and progress per
/// app, Cancel on the ones still waiting, and a click to open any of them.
struct ActivityPanel: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var runs: RunCenter
    @ObservedObject var identities: AppIdentityStore
    var title = "Activity"
    /// Left out of the list — the simple screen already shows the app on
    /// screen in full above it.
    var excluding: UUID?

    private var entries: [ShipProfile] {
        runs.recent.compactMap { id in
            id == excluding ? nil : store.profiles.first { $0.id == id }
        }
    }

    var body: some View {
        let entries = entries
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title).font(Design.Face.heading)
                    if runs.busyCount > 0 {
                        Text(summary).font(Design.Face.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if runs.hasFinished {
                        Button("Clear") { runs.clearFinished() }
                            .buttonStyle(.borderless)
                            .font(Design.Face.caption)
                            .help("Take finished apps off this list. Their builds and logs stay with them.")
                    }
                }
                ForEach(entries) { profile in
                    ActivityRow(
                        runner: runs.runner(for: profile.id),
                        profile: profile,
                        identity: identities.identity(for: profile),
                        selected: profile.id == store.selectedID,
                        open: { store.selectedID = profile.id },
                        cancel: { runs.cancelQueued(profile.id) },
                    )
                }
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if !runs.running.isEmpty { parts.append("\(runs.running.count) building") }
        if !runs.queued.isEmpty { parts.append("\(runs.queued.count) waiting") }
        return parts.joined(separator: " · ")
    }
}

private struct ActivityRow: View {
    @ObservedObject var runner: Runner
    let profile: ShipProfile
    let identity: AppIdentity?
    let selected: Bool
    let open: () -> Void
    let cancel: () -> Void

    @State private var hovering = false

    private var name: String {
        ProfileStore.isPlaceholderName(profile.name)
            ? (identity?.displayName ?? profile.name) : profile.name
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                AppIconThumb(icon: identity?.icon, name: name, size: 22, corner: 5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        PlatformMark(platform: profile.knownPlatform)
                        Spacer(minLength: 4)
                        RunBadge(runner: runner)
                    }
                    if runner.isRunning {
                        ThinProgress(value: runner.progress)
                    }
                    HStack(spacing: 4) {
                        Text(detail)
                            .font(Design.Face.caption)
                            .foregroundStyle(runner.failed ? Design.failure : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(runner.status)
                        Spacer(minLength: 0)
                        if runner.isQueued {
                            Button("Cancel", action: cancel)
                                .buttonStyle(.borderless)
                                .font(Design.Face.caption)
                        }
                    }
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Design.accentSolid.opacity(0.10)
                          : Color.primary.opacity(hovering ? 0.06 : 0)),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(name)")
    }

    private var detail: String {
        if runner.isQueued { return "Waiting for a free slot" }
        if runner.isRunning {
            guard let stage = runner.currentStage else { return "Reading the project…" }
            return stage.title + (runner.stagePosition.map { " · \($0)" } ?? "")
        }
        if runner.failed { return runner.status }
        if let result = runner.result {
            return result.uploaded ? "Uploaded to App Store Connect" : "Built · \(result.name)"
        }
        return runner.status
    }
}

/// A run's status for a row that does not observe the runner itself: the
/// badge in words, and a progress bar while it is going.
struct RunStatusColumn: View {
    @ObservedObject var runner: Runner

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            RunBadge(runner: runner, showsLabel: true)
            if runner.isRunning {
                ThinProgress(value: runner.progress).frame(width: 96)
            }
        }
    }
}

// MARK: - Ship Many

/// Pick several apps and ship them together.
///
/// Each one goes through exactly the run its own Deploy button would start —
/// its project read afresh, its own profile, its own log — up to the parallel
/// limit at once and the rest queued behind. The sheet can be closed at any
/// point; the runs carry on, and the profile list shows how each is getting on.
struct ShipManyView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var runs: RunCenter
    @ObservedObject var identities: AppIdentityStore
    var dismiss: () -> Void

    @State private var chosen: Set<UUID> = []
    @State private var upload = true
    /// The list as it stood when the sheet opened. Starting a run marks its
    /// profile as just used, which reorders the live list — rows jumping
    /// about under the pointer the moment Start is pressed.
    @State private var order: [(id: UUID, nested: Bool)] = []

    private var sorted: [ShipProfile] {
        order.compactMap { entry in store.profiles.first { $0.id == entry.id } }
    }

    private func isNested(_ id: UUID) -> Bool {
        order.first { $0.id == id }?.nested ?? false
    }

    private func isReady(_ profile: ShipProfile) -> Bool {
        store.problems(for: profile).isEmpty
    }

    /// Chosen, ready and not already going — what Start would actually start.
    private var startable: [ShipProfile] {
        sorted.filter { chosen.contains($0.id) && isReady($0) && !runs.isBusy($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            options
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(sorted) { profile in
                        row(profile)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 240, maxHeight: 420)
            Divider()
            footer
        }
        .frame(width: 640)
        .onAppear {
            order = store.listOrder.map { ($0.id, $0.nested) }
            chooseDefault()
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: Design.Gap.medium) {
            SectionIcon(symbol: "square.stack.3d.up.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text("Ship many").font(Design.Face.title)
                Text("Tick the apps to build — iPhone, iPad and Mac versions alike. "
                     + "They run side by side; you can close this and keep working.")
                    .font(Design.Face.label).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if runs.busyCount > 0 {
                Pill(text: "\(runs.running.count) running"
                     + (runs.queued.isEmpty ? "" : " · \(runs.queued.count) queued"),
                     color: Design.accentSolid)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var options: some View {
        HStack(spacing: Design.Gap.medium) {
            Picker("", selection: $upload) {
                Text("Build & Upload").tag(true)
                Text("Build only").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()

            Spacer()

            Text("At most").font(Design.Face.label).foregroundStyle(.secondary)
            Stepper(value: $runs.limit, in: RunCenter.limits) {
                Text("\(runs.limit) at once")
                    .font(Design.Face.body.monospacedDigit())
                    .frame(minWidth: 62, alignment: .leading)
            }
            .help("How many apps archive side by side. The rest wait their turn and start "
                  + "as soon as one finishes.")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func row(_ profile: ShipProfile) -> some View {
        let problems = store.problems(for: profile)
        let busy = runs.isBusy(profile.id)
        let identity = identities.identity(for: profile)
        let name = ProfileStore.isPlaceholderName(profile.name)
            ? (identity?.displayName ?? profile.name) : profile.name

        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { chosen.contains(profile.id) },
                set: { on in
                    if on { chosen.insert(profile.id) } else { chosen.remove(profile.id) }
                },
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!problems.isEmpty || busy)

            // Clicking the name ticks the box too. Kept off the checkbox
            // itself, which would then toggle twice.
            HStack(spacing: 10) {
                AppIconThumb(icon: identity?.icon, name: name,
                             size: isNested(profile.id) ? 22 : 26, corner: isNested(profile.id) ? 5 : 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    HStack(spacing: 5) {
                        if let platform = profile.knownPlatform {
                            Pill(text: platform.displayName, color: .secondary, symbol: platform.symbol)
                        }
                        Text(profile.bundleID.isEmpty ? "Not configured" : profile.bundleID)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard problems.isEmpty, !busy else { return }
                if chosen.contains(profile.id) { chosen.remove(profile.id) } else { chosen.insert(profile.id) }
            }

            if let activity = runs.activity(for: profile.id) {
                RunStatusColumn(runner: activity)
                if runs.queued.contains(profile.id) {
                    Button("Cancel") { runs.cancelQueued(profile.id) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            } else if let first = problems.first {
                Text(first)
                    .font(Design.Face.caption)
                    .foregroundStyle(Design.warning)
                    .lineLimit(1)
                    .help(problems.joined(separator: "\n"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(chosen.contains(profile.id) ? Design.accentSolid.opacity(0.08) : .clear),
        )
        // A further version of the app above: drawn as part of it.
        .padding(.leading, isNested(profile.id) ? 24 : 0)
        .opacity(problems.isEmpty ? 1 : 0.6)
        .task(id: profile.projectPath + profile.bundleID) { await identities.load(profile) }
    }

    private var footer: some View {
        HStack(spacing: Design.Gap.small) {
            QuietButton(title: "This app", symbol: "square.on.square") { chooseDefault() }
                .help("\(store.current.name) and its other platform versions")
            QuietButton(title: "All ready", symbol: "checklist") {
                chosen = Set(sorted.filter { isReady($0) && !runs.isBusy($0.id) }.map(\.id))
            }
            QuietButton(title: "None", symbol: "xmark") { chosen = [] }

            Spacer()

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)

            PrimaryButton(
                title: startable.isEmpty
                    ? "Start"
                    : "\(upload ? "Ship" : "Build") \(startable.count) app\(startable.count == 1 ? "" : "s")",
                symbol: upload ? "arrow.up.circle.fill" : "hammer.fill",
                enabled: !startable.isEmpty,
            ) { start() }
            .frame(width: 170)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    // MARK: Actions

    /// The app on screen and its other platform versions — the usual reason
    /// to open this sheet is "ship the iPhone and the Mac app together".
    private func chooseDefault() {
        let current = store.current
        let family = [current] + store.platformVersions(of: current)
        chosen = Set(family.filter { isReady($0) && !runs.isBusy($0.id) }.map(\.id))
    }

    private func start() {
        let upload = upload
        let starting = startable
        chosen.subtract(starting.map(\.id))
        for profile in starting {
            let id = profile.id
            store.markUsed(id)
            runs.submit(
                id, upload: upload, revealWhenBuilt: false,
                onIdentityCreated: { [store] path in
                    store.update(id) { $0.identityPath = path }
                },
            ) { [store] log in
                // Read at the moment the run starts, not when it was queued:
                // anything edited while it waited is what should ship.
                guard let latest = store.profiles.first(where: { $0.id == id }) else {
                    throw ShipError("That profile was deleted before its turn came.")
                }
                let resolved = await RunPlan.resolve(latest, configuration: .release, log: log)
                store.adoptResolved(resolved.profile)
                return resolved.input
            }
        }
    }
}
