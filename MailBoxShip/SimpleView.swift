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

    @State private var detected = ProjectInspector.Info()
    @State private var detecting = false
    @State private var note = ""
    @State private var noteWarn = false
    @State private var team = ""
    @State private var copiedLog = false
    @State private var showSync = false

    private var p: ShipProfile { store.current }
    private var bothChosen: Bool { !p.projectPath.isEmpty && !p.keyPath.isEmpty }
    private var problems: [String] { store.problems() }
    private var ready: Bool { problems.isEmpty && !runner.isRunning }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    steps
                    if bothChosen { summary }
                    actions
                    if runner.isRunning || runner.finished || !runner.log.isEmpty { progress }
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: store.selectedID) {
            store.applyBakedProxyIfNeeded()
            await detect()
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

            VStack(alignment: .leading, spacing: 1) {
                Text("MailBoxShip").font(.system(size: 15, weight: .semibold))
                Text("Pick a project and key, then deploy")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Spacer()

            clientMenu

            Button { showSync = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10))
                    Text("Sync").font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            .help("Sync profiles and keys across your Macs")

            Button(action: onAdvanced) {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 10))
                    Text("Advanced").font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            .help("Open the full interface with every option")
            .disabled(runner.isRunning)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// Switch between saved clients, or start a new one — the only trace of the
    /// multi-profile model the simple screen keeps.
    private var clientMenu: some View {
        Menu {
            ForEach(store.profiles.sorted { $0.lastUsed > $1.lastUsed }) { profile in
                Button {
                    store.selectedID = profile.id
                } label: {
                    Label(profile.name, systemImage: profile.id == store.selectedID
                          ? "checkmark" : "person.crop.circle")
                }
            }
            Divider()
            Button {
                store.addProfile()
            } label: { Label("New client", systemImage: "plus") }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle").font(.system(size: 11))
                Text(p.name).font(.system(size: 11)).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(runner.isRunning)
    }

    // MARK: - Steps

    private var steps: some View {
        VStack(spacing: 12) {
            stepCard(number: 1, title: "Xcode project",
                     subtitle: "Choose the .xcodeproj — or drop it here") {
                PathField(path: p.projectPath, prompt: "Choose…",
                          types: [UTType(filenameExtension: "xcodeproj") ?? .directory]) { chosen in
                    guard let resolved = ProjectInspector.resolveProject(at: chosen) else {
                        note = "No .xcodeproj found in that folder."; noteWarn = true; return
                    }
                    store.adoptProject(path: resolved)
                    Task { await detect(); await fetchTeam() }
                }
            }

            stepCard(number: 2, title: "App Store Connect key",
                     subtitle: "Drop the AuthKey_….p8 from any folder") {
                PathField(path: p.keyPath, prompt: "Choose…",
                          types: [UTType(filenameExtension: "p8") ?? .data]) { chosen in
                    store.adoptKey(path: chosen)
                    Task { await fetchTeam() }
                }
            }
        }
    }

    private func stepCard<Content: View>(
        number: Int, title: String, subtitle: String,
        @ViewBuilder content: () -> Content,
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Design.accent).frame(width: 24, height: 24)
                Text("\(number)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 13, weight: .semibold))
                content()
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
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

            issuerRow
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    /// Only asks for the issuer when nothing could resolve it — a known key, a
    /// saved profile or the baked registry all skip this entirely.
    @ViewBuilder private var issuerRow: some View {
        if p.issuerID.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle").font(.system(size: 11))
                    .foregroundStyle(Design.warning)
                TextField("Issuer ID (once — then remembered)",
                          text: store.binding(\.issuerID))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 11))
                    .foregroundStyle(Design.success)
                Text("Issuer resolved").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
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
                platform: detected.platform,
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
