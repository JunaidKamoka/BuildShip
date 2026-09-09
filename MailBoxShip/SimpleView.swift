import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The one-screen deploy: pick a project folder and a `.p8`, press Deploy.
///
/// Everything else — scheme, bundle id, version, build, team, issuer and the
/// egress proxy — is detected from the project, read from the key filename, or
/// resolved from the baked `Deployment` config. The advanced screen still holds
/// every knob; this one is the path most runs actually take.
struct SimpleView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var runner: Runner
    @ObservedObject var sync: SyncStore
    var onAdvanced: () -> Void

    /// Real app icons and names, read from each profile's project — the same
    /// walk the advanced screen does, so the client you are about to ship is
    /// recognisable by its own icon rather than a row of identical glyphs.
    @StateObject private var identities = AppIdentityStore()

    @State private var detected = ProjectInspector.Info()
    @State private var detecting = false
    @State private var note = ""
    @State private var noteWarn = false
    @State private var team = ""
    @State private var copiedLog = false
    @State private var showSync = false
    /// Checked once rather than per render — it is a handful of filesystem
    /// probes, and a view body is not the place for them.
    @State private var uploaderInstalled = true
    /// Reveals the Issuer ID field even once one is set, so a resolved-but-wrong
    /// value can be corrected without going to the advanced screen.
    @State private var editingIssuer = false

    private var p: ShipProfile { store.current }
    private var bothChosen: Bool { !p.projectPath.isEmpty && !p.keyPath.isEmpty }
    private var problems: [String] { store.problems() }

    /// Detection has to finish before a run can start. Every field `problems()`
    /// checks is saved, so the button is otherwise live the instant the window
    /// opens — and a run started there is built from whatever the *previous*
    /// project left in state.
    private var ready: Bool { problems.isEmpty && !runner.isRunning && !detecting }

    /// The platform this run ships as: the user's explicit choice, else whatever
    /// the project detected. What actually gets built and uploaded.
    private var selectedPlatform: ShipPlatform { p.shipPlatform(detected: detected.platform) }

    /// Writes the segmented picker's choice back to the profile as an explicit
    /// override, so it persists and the other platform can be shipped next time.
    private var platformBinding: Binding<ShipPlatform> {
        Binding(
            get: { selectedPlatform },
            set: { store.binding(\.platformRaw).wrappedValue = $0.rawValue },
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    steps
                    if bothChosen { summary }
                    actions
                    if let result = runner.result {
                        ResultCard(result: result)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if runner.isRunning || runner.finished || !runner.log.isEmpty { progress }
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: runner.result)
        .task(id: store.selectedID) {
            store.applyBakedProxyIfNeeded()
            uploaderInstalled = Transporter.isInstalled
            // A saved profile already knows its bundle id, so this shows the
            // icon at once; the reload after detection only walks again on the
            // first configuration, when the id has just been discovered.
            await identities.load(store.current)
            await detect()
            await identities.load(store.current)
            await fetchTeam()
        }
        .sheet(isPresented: $showSync) { SyncView(sync: sync) }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Design.accent)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white))
                .shadow(color: Design.accentSolid.opacity(0.28), radius: 4, y: 1.5)

            VStack(alignment: .leading, spacing: 1) {
                Text("MailBoxShip").font(.system(size: 15, weight: .semibold))
                Text("Pick a project and key, then deploy")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Spacer()

            ClientSwitcher(store: store, identities: identities, disabled: runner.isRunning)

            QuietButton(title: "Builds", symbol: "tray.full") { Builds.open() }
                .help("Open the folder every finished build is kept in")
            QuietButton(title: "Sync", symbol: "arrow.triangle.2.circlepath") { showSync = true }
                .help("Sync profiles and keys across your Macs")
            QuietButton(title: "Advanced", symbol: "slider.horizontal.3",
                        enabled: !runner.isRunning, action: onAdvanced)
                .help("Open the full interface with every option")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Steps

    private var steps: some View {
        VStack(spacing: 12) {
            StepCard(number: 1, title: "Xcode project",
                     subtitle: "Choose the .xcodeproj — or drop it here",
                     done: !p.projectPath.isEmpty) {
                PathField(path: p.projectPath, prompt: "Choose…",
                          types: [UTType(filenameExtension: "xcodeproj") ?? .directory]) { chosen in
                    guard let resolved = ProjectInspector.resolveProject(at: chosen) else {
                        note = "No .xcodeproj found in that folder."; noteWarn = true; return
                    }
                    store.adoptProject(path: resolved)
                    Task { await detect(); await identities.load(store.current); await fetchTeam() }
                }
            }

            StepCard(number: 2, title: "App Store Connect key",
                     subtitle: "Drop the AuthKey_….p8 from any folder",
                     done: !p.keyPath.isEmpty,
                     footer: AnyView(issuerField)) {
                PathField(path: p.keyPath, prompt: "Choose…",
                          types: [UTType(filenameExtension: "p8") ?? .data]) { chosen in
                    store.adoptKey(path: chosen)
                    Task { await fetchTeam() }
                }
            }
        }
    }

    // MARK: - Auto-detected summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").font(.system(size: 12))
                    .foregroundStyle(Design.accent)
                Text("Detected automatically").font(.system(size: 12, weight: .semibold))
                Spacer()
                if detecting { ProgressView().controlSize(.small).scaleEffect(0.7) }
            }

            WrapChips {
                chip(icon: "app.badge",
                     text: p.bundleID.isEmpty ? "reading project…" : p.bundleID,
                     good: !p.bundleID.isEmpty)
                if !displayVersion.isEmpty {
                    chip(icon: "number", text: "v\(displayVersion) (\(displayBuild))", good: true)
                }
                if !detected.extensionBundleIDs.isEmpty {
                    chip(icon: "puzzlepiece.extension",
                         text: "+\(detected.extensionBundleIDs.count) extension", good: true)
                }
                chip(icon: "key", text: p.keyID.isEmpty ? "no key id" : p.keyID,
                     good: p.keyID.count == 10)
                if !team.isEmpty { chip(icon: "person.2", text: "Team \(team)", good: true) }
            }

            platformRow
            uploaderRow
            if Deployment.proxyConfigured { proxyRow }

            if !note.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: noteWarn ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(noteWarn ? Design.warning : Design.success)
                    Text(note).font(.system(size: 11))
                        .foregroundStyle(noteWarn ? Design.warning : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .cardSurface(padding: 14)
    }

    /// Which platform to upload. Defaults to what the project detected, but a
    /// scheme that builds both a Mac and an iPhone app under the same bundle id
    /// can only be detected as one — so this lets the other be chosen and shipped.
    private var platformRow: some View {
        HStack(spacing: 8) {
            Image(systemName: selectedPlatform.symbol).font(.system(size: 11))
                .foregroundStyle(Design.accent)
            Text("Upload as").font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("", selection: platformBinding) {
                ForEach(ShipPlatform.allCases) { platform in
                    Text(platform.displayName).tag(platform)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(runner.isRunning)
            if p.platformOverride == nil {
                Text("detected").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Says up front when this Mac cannot upload at all.
    ///
    /// Xcode 26 dropped the uploader, so a Mac with Xcode alone can build and
    /// sign perfectly and then fail at the last step. That is worth knowing
    /// beside the other preconditions rather than after a five-minute build —
    /// and it is a missing *app*, so nothing this tool does can resolve it.
    @ViewBuilder private var uploaderRow: some View {
        if !uploaderInstalled {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    .foregroundStyle(Design.warning)
                Text("No uploader — install Apple's free Transporter to deploy.")
                    .font(.system(size: 11)).foregroundStyle(Design.warning)
                Link("Get it", destination: URL(
                    string: "https://apps.apple.com/app/transporter/id1450874784")!)
                    .font(.system(size: 11))
                Spacer()
            }
        }
    }

    /// The issuer id, kept with the key it belongs to and always reachable.
    ///
    /// It resolves itself most of the time — from a known key, a saved profile
    /// or the baked registry — which is why it used to appear only when it
    /// could not. But one that resolved to the *wrong* account left nowhere to
    /// correct it without crossing into the advanced screen, and a resolved
    /// value you cannot see is one you cannot check. So it shows either way:
    /// quiet when it is settled, a field the moment it is not.
    @ViewBuilder private var issuerField: some View {
        if p.issuerID.isEmpty || editingIssuer || store.issuerLooksWrong {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: p.issuerID.isEmpty ? "questionmark.circle" : "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(p.issuerID.isEmpty ? Design.warning : Color.secondary)
                    ShipTextField("Issuer ID — the UUID beside the key in App Store Connect", text: store.binding(\.issuerID), mono: true)
                        .onSubmit { finishIssuer() }
                    if p.issuerID.isEmpty {
                        Pill(text: "Required", color: Design.warning)
                    } else if store.issuerLooksWrong {
                        Pill(text: "expects a UUID", color: Design.warning,
                             symbol: "exclamationmark")
                    } else {
                        Button("Done") { finishIssuer() }
                            .controlSize(.small)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                // Nothing else on this screen says where to find it, and the
                // commonest wrong answer — the Key ID, which is right there on
                // the same page — is the one that fails as a bare 401.
                if p.issuerID.isEmpty || store.issuerLooksWrong {
                    Text("App Store Connect → Users and Access → Integrations. "
                         + "It is the long UUID above the key list, the same for "
                         + "every key on the account.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 11))
                    .foregroundStyle(Design.success)
                Text(p.issuerID)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help("Issuer ID")
                Spacer(minLength: 6)
                Button("Change") { editingIssuer = true }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(runner.isRunning)
            }
        }
    }

    /// A changed issuer is a different account — re-read the team behind it, so
    /// a wrong one is caught here rather than by a failed run.
    private func finishIssuer() {
        editingIssuer = false
        Task { await fetchTeam() }
    }

    private var proxyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "network").font(.system(size: 11)).foregroundStyle(Design.accent)
            Text(p.proxy.isUsable
                 ? "Proxy \(p.proxy.host):\(p.proxy.port)"
                 : "Proxy configured")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Circle().fill(Design.success).frame(width: 6, height: 6)
            Spacer()
            Button {
                store.rotateProxyIP()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9))
                    Text("New IP").font(.system(size: 11))
                }
            }
            .controlSize(.small)
            .disabled(runner.isRunning)
            .help("Rotate to a fresh stable exit IP")
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 8) {
            PrimaryButton(
                title: runner.isRunning ? "Working…" : "Deploy to App Store",
                symbol: runner.isRunning ? "hourglass" : "arrow.up.circle.fill",
                enabled: ready,
            ) { deploy(upload: true) }

            HStack {
                Button {
                    deploy(upload: false)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hammer").font(.system(size: 10))
                        Text("Build IPA only").font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!ready)

                Spacer()

                if !ready, bothChosen, let first = problems.first {
                    Text(first).font(.system(size: 11)).foregroundStyle(Design.warning)
                } else if detecting, !runner.isRunning {
                    // Say why the button is inert, rather than leaving a ready
                    // -looking screen with a dead button on it.
                    Text("Reading the project…").font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Progress + log

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !runner.steps.isEmpty { stageStrip }

            HStack(spacing: 6) {
                if runner.isRunning { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Text(runner.status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(runner.failed ? Design.failure
                                     : runner.finished ? Design.success : .primary)
                    .lineLimit(2)
                Spacer()
            }

            if !runner.log.isEmpty { logConsole }
        }
        .cardSurface(padding: 14)
    }

    private var stageStrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(runner.steps.enumerated()), id: \.element.id) { index, stage in
                let state = runner.state(of: stage)
                ZStack {
                    Circle().fill(state.tint.opacity(state == .pending ? 0.12 : 0.18))
                        .frame(width: 20, height: 20)
                    if state == .active {
                        ProgressView().controlSize(.small).scaleEffect(0.5)
                    } else {
                        Image(systemName: state == .done ? "checkmark"
                              : state == .failed ? "xmark" : stage.symbol)
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(state.tint)
                    }
                }
                .help(stage.title)

                if index < runner.steps.count - 1 {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                        .frame(maxWidth: .infinity).padding(.horizontal, 4)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: runner.currentStage)
    }

    private var logConsole: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.fullLog, forType: .string)
                    copiedLog = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copiedLog = false }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copiedLog ? "checkmark" : "doc.on.doc").font(.system(size: 9))
                        Text(copiedLog ? "Copied" : "Copy").font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
            }
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.log)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("bottom")
                }
                .frame(height: 200)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04)))
                .onChange(of: runner.log) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: - Chips

    private var displayVersion: String {
        p.marketingVersion.isEmpty ? detected.marketingVersion : p.marketingVersion
    }
    private var displayBuild: String {
        let b = p.buildNumber.isEmpty ? detected.buildNumber : p.buildNumber
        return b.isEmpty ? "auto" : "b\(b)"
    }

    private func chip(icon: String, text: String, good: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 11, design: .monospaced)).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill((good ? Design.success : Design.warning).opacity(0.12)))
        .foregroundStyle(good ? Design.success : Design.warning)
    }

    // MARK: - Work

    private func detect() async {
        var path = store.current.projectPath
        guard !path.isEmpty, !detecting else { return }
        detecting = true
        note = "Reading project…"; noteWarn = false
        defer { detecting = false }

        // Self-heal a stored path that points at a broken or renamed project —
        // a leftover Craftly.xcodeproj beside the real one, say — so the tool
        // reads what actually builds instead of repeating the same failure.
        if let resolved = ProjectInspector.resolveProject(at: path), resolved != path {
            store.binding(\.projectPath).wrappedValue = resolved
            path = resolved
        }

        let (schemes, _) = await ProjectInspector.list(projectPath: path)
        guard !schemes.isEmpty else {
            detected = ProjectInspector.Info()
            note = "No shared scheme found. Open the project in Xcode and mark a scheme Shared."
            noteWarn = true
            return
        }

        let scheme = schemes.contains(store.current.scheme) ? store.current.scheme : schemes[0]
        if store.current.scheme != scheme { store.binding(\.scheme).wrappedValue = scheme }

        var info = await ProjectInspector.inspect(projectPath: path, scheme: scheme)
        info.schemes = schemes
        detected = info

        // Remember the platform, so the next launch knows this is a Mac app
        // before it has had time to read the project again.
        if let platform = info.platform {
            store.binding(\.detectedPlatformRaw).wrappedValue = platform.rawValue
        }

        // The simple screen has no bundle-id field to reconcile, so it trusts
        // what the scheme actually builds and adopts it outright.
        if !info.bundleID.isEmpty {
            store.binding(\.bundleID).wrappedValue = info.bundleID
            store.binding(\.extensionBundleIDsRaw).wrappedValue =
                info.extensionBundleIDs.joined(separator: ", ")
            note = "Ready: \(info.summary)"
            noteWarn = false
        } else {
            note = "Could not read a bundle id from scheme \(scheme)."
            noteWarn = true
        }
    }

    /// Show the team behind the key, as a quiet confirmation the credentials are
    /// good before a five-minute build spends itself finding out otherwise.
    private func fetchTeam() async {
        let p = store.current
        guard !p.keyPath.isEmpty, !p.keyID.isEmpty, !p.issuerID.isEmpty,
              FileManager.default.fileExists(atPath: p.keyPath) else { team = ""; return }
        let api = ASCClient(keyID: p.keyID, issuerID: p.issuerID,
                            privateKeyPath: p.keyPath,
                            proxyDictionary: p.proxy.sessionProxyDictionary)
        team = (try? await api.teamID()) ?? ""
    }

    private func deploy(upload: Bool) {
        let problems = store.problems()
        guard problems.isEmpty else {
            runner.fail(problems.first ?? "Not ready",
                        detail: "Before starting:\n" + problems.map { "  • \($0)" }.joined(separator: "\n"))
            return
        }
        store.markUsed()
        store.save()
        runner.onIdentityCreated = { path in
            store.binding(\.identityPath).wrappedValue = path
        }
        runner.run(
            input: Pipeline.Input(
                profile: store.current,
                configuration: .release,
                platform: selectedPlatform,
                entitlementsByBundleID: detected.entitlements,
            ),
            upload: upload,
        )
    }
}

/// A left-aligned flow layout so the detected chips wrap instead of clipping.
struct WrapChips: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - App icon

/// A profile's real app icon, or an accent tile carrying its initial until one
/// has been read. The single place the simple screen turns an `NSImage` into a
/// thumbnail, so the topbar badge, the switcher and every menu row round and
/// size it the same way.
struct AppIconThumb: View {
    let icon: NSImage?
    let name: String
    var size: CGFloat = 26
    var corner: CGFloat = 6

    @ViewBuilder
    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                // iOS icons ship square and are masked by the system; a Mac
                // icon already rounds itself and is padded to the corners, so
                // the same clip leaves it untouched.
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
        } else {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Design.accent)
                .frame(width: size, height: size)
                .overlay(
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.46, weight: .bold))
                        .foregroundStyle(.white),
                )
        }
    }
}

// MARK: - Step card

/// A numbered step whose badge flips to a green check the moment its input is
/// satisfied, so the two things this screen needs read as a short checklist
/// rather than two identical panels — and the card lifts under the pointer to
/// say it is the thing being acted on.
private struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let subtitle: String
    var done: Bool
    var footer: AnyView?
    let content: Content

    @State private var hovering = false

    init(
        number: Int, title: String, subtitle: String, done: Bool = false,
        footer: AnyView? = nil, @ViewBuilder content: () -> Content,
    ) {
        self.number = number
        self.title = title
        self.subtitle = subtitle
        self.done = done
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? AnyShapeStyle(Design.success) : AnyShapeStyle(Design.accent))
                    .frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                }
            }
            .animation(.easeOut(duration: 0.18), value: done)

            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 13, weight: .semibold))
                content
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                if let footer {
                    Divider().padding(.vertical, 1)
                    footer
                }
            }
        }
        .cardSurface(padding: 14)
        .overlay(
            RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
                .strokeBorder(done ? Design.success.opacity(0.35) : Color.clear, lineWidth: 1),
        )
        .shadow(color: .black.opacity(hovering ? 0.09 : 0), radius: hovering ? 6 : 0, y: 2)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Client switcher

/// Switch between saved clients, or start a new one — the simple screen's one
/// trace of the multi-profile model.
///
/// A popover rather than a system `Menu`, because the point is the *icon*: a
/// list where each client is its own artwork is the fastest way to be sure
/// which app is about to ship, and a native menu renders that artwork as a flat
/// template glyph.
private struct ClientSwitcher: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var identities: AppIdentityStore
    var disabled: Bool

    @State private var showing = false
    @State private var hovering = false

    private var current: ShipProfile { store.current }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 7) {
                AppIconThumb(icon: identities.identity(for: current)?.icon,
                             name: current.name, size: 22, corner: 5)
                Text(displayName(current))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0.05)),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Design.hairline, lineWidth: 1),
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Switch the client app this run ships")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ClientList(store: store, identities: identities) { showing = false }
        }
    }

    private func displayName(_ profile: ShipProfile) -> String {
        if ProfileStore.isPlaceholderName(profile.name),
           let real = identities.identity(for: profile)?.displayName {
            return real
        }
        return profile.name
    }
}

/// The popover body: every saved client as a row of its own icon, name and
/// identifier, then a way to start a new one.
private struct ClientList: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var identities: AppIdentityStore
    var dismiss: () -> Void

    private var sorted: [ShipProfile] {
        store.profiles.sorted { $0.lastUsed > $1.lastUsed }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(sorted) { profile in
                        ClientRow(profile: profile,
                                  identity: identities.identity(for: profile),
                                  selected: profile.id == store.selectedID) {
                            store.selectedID = profile.id
                            dismiss()
                        }
                        .task(id: profile.projectPath + profile.bundleID) {
                            guard let found = await identities.load(profile),
                                  let name = found.displayName else { return }
                            store.adoptDisplayName(name, forProjectPath: profile.projectPath)
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 360)

            Divider()

            NewClientRow {
                store.addProfile()
                dismiss()
            }
        }
        .frame(width: 288)
    }
}

/// One client in the switcher popover.
private struct ClientRow: View {
    let profile: ShipProfile
    let identity: AppIdentity?
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    private var name: String {
        if ProfileStore.isPlaceholderName(profile.name), let real = identity?.displayName {
            return real
        }
        return profile.name
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AppIconThumb(icon: identity?.icon, name: name, size: 26, corner: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(profile.bundleID.isEmpty ? "Not configured" : profile.bundleID)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }

                Spacer(minLength: 4)

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(Design.accentSolid)
                } else if !profile.missingFiles.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(Design.warning)
                        .help("\(profile.missingFiles.joined(separator: " and ")) missing on disk")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Design.accentSolid.opacity(0.12)
                          : Color.primary.opacity(hovering ? 0.06 : 0)),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// The footer action that mints a fresh client.
private struct NewClientRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Design.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(width: 26, height: 26)
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Design.accentSolid)
                }
                Text("New client").font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0)),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}
