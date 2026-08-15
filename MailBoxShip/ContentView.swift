import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AdvancedView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var runner: Runner
    @ObservedObject var sync: SyncStore
    /// Return to the simple screen. Injected by the root so the two screens
    /// share one store and one runner — switching never loses a selection or a
    /// run in flight.
    var onSimple: () -> Void = {}

    @State private var configuration: Pipeline.Configuration = .release
    @State private var renaming = false
    @State private var draftName = ""
    @State private var showingStorageInfo = false
    @State private var showingLog = false
    @State private var showSync = false

    @State private var detected = ProjectInspector.Info()
    @State private var detecting = false
    @State private var detectionNote = ""
    @State private var detectionWarning = false

    // TestFlight
    @State private var builds: [ASCClient.BuildInfo] = []
    @State private var groups: [ASCClient.BetaGroup] = []
    @State private var loadingTestFlight = false
    @State private var testFlightNote = ""
    @State private var copiedLink = false

    // Beta App Review contact + demo account
    @State private var review: ASCClient.ReviewDetail?
    @State private var savingReview = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 640)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedID) {
                Section("Profiles") {
                    ForEach(store.profiles.sorted { $0.lastUsed > $1.lastUsed }) { profile in
                        profileRow(profile).tag(profile.id)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 2) {
                sidebarButton("plus", "New profile") { store.addProfile() }
                sidebarButton("plus.square.on.square", "Duplicate") { store.duplicateSelected() }
                sidebarButton("pencil", "Rename") {
                    draftName = store.current.name
                    renaming = true
                }
                Spacer()
                sidebarButton("arrow.triangle.2.circlepath", "Sync across Macs") { showSync = true }
                sidebarButton("info.circle", "Where profiles are stored") { showingStorageInfo = true }
                sidebarButton("trash", "Delete") { store.deleteSelected() }
                    .disabled(store.profiles.count <= 1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .disabled(runner.isRunning)
        .alert("Rename profile", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { store.rename(to: draftName) }
        }
        .alert("Where everything is stored", isPresented: $showingStorageInfo) {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: store.storageDescription)])
            }
            Button("Move…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = "Use Folder"
                if panel.runModal() == .OK, let url = panel.url {
                    SecretStore.shared.relocate(to: url.path)
                    store.reload()
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(store.storageDescription)\n\n"
                 + "Everything lives in this one file: stores, paths, identifiers and "
                 + "passwords. It sits outside the app, so deleting or replacing "
                 + "MailBoxShip.app leaves it untouched and the next install picks it "
                 + "straight back up.\n\n"
                 + "Not in it: the .p8 and .p12 themselves — only their paths.\n\n"
                 + "It is plaintext and owner-readable only. No Keychain is used.")
        }
    }

    private func profileRow(_ profile: ShipProfile) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Design.accent)
                .frame(width: 26, height: 26)
                .overlay(
                    Text(String(profile.name.prefix(1)).uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white),
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(profile.bundleID.isEmpty ? "Not configured" : profile.bundleID)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if !profile.missingFiles.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Design.warning)
                    .help("\(profile.missingFiles.joined(separator: " and ")) missing on disk")
            }
        }
        .padding(.vertical, 3)
    }

    private func sidebarButton(
        _ symbol: String, _ help: String, action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 14) {
                    projectCard
                    credentialsCard
                    proxyCard
                    testFlightCard
                    releaseCard
                }
                .padding(18)
            }

            Divider()
            runBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingLog) { logSheet }
        .sheet(isPresented: $showSync) { SyncView(sync: sync) }
        // Read the project on arrival and whenever another profile is selected.
        // Detection state is per-view, not stored, so without this a freshly
        // opened window shows a scheme text field instead of the project's
        // actual schemes and cannot notice a stale identifier until someone
        // thinks to press Detect. Never adopts — arriving somewhere is not a
        // decision to change it.
        .task(id: store.selectedID) { await detect() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Design.accent)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white),
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(store.current.name)
                    .font(.system(size: 17, weight: .semibold))
                HStack(spacing: 6) {
                    Text(store.current.bundleID.isEmpty
                         ? "No bundle identifier yet" : store.current.bundleID)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if !detected.extensionBundleIDs.isEmpty {
                        Pill(text: "+\(detected.extensionBundleIDs.count) extension",
                             color: .secondary)
                    }
                }
            }

            Spacer()

            if !detected.marketingVersion.isEmpty {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(store.current.marketingVersion.isEmpty ? detected.marketingVersion : store.current.marketingVersion)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("build \(store.current.buildNumber.isEmpty ? detected.buildNumber : store.current.buildNumber)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onSimple) {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars").font(.system(size: 10))
                    Text("Simple").font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            .help("Switch to the simple one-screen deploy")
            .disabled(runner.isRunning)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Cards

    private var projectCard: some View {
        Card("Project", symbol: "hammer.fill", accessory: AnyView(
            Button {
                Task { await detect() }
            } label: {
                HStack(spacing: 4) {
                    if detecting { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                    Text("Detect").font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            .disabled(detecting || store.current.projectPath.isEmpty || runner.isRunning),
        )) {
            Row("Xcode project") {
                pathField(
                    path: store.current.projectPath,
                    prompt: "Choose…",
                    types: [UTType(filenameExtension: "xcodeproj") ?? .directory],
                ) { chosen in
                    // A .xcodeproj is a package, so the panel must allow
                    // directories — which makes picking the enclosing folder an
                    // easy mistake. Resolve it rather than failing later.
                    guard let resolved = ProjectInspector.resolveProject(at: chosen) else {
                        detectionNote = "No .xcodeproj found in that folder."
                        detectionWarning = true
                        return
                    }
                    store.adoptProject(path: resolved)
                    Task { await detect(adopting: true) }
                }
            }

            Row("Scheme") {
                if detected.schemes.isEmpty {
                    TextField("MailBox", text: store.binding(\.scheme))
                        .textFieldStyle(.roundedBorder)
                } else {
                    // Bound by hand rather than through `store.binding`, so that
                    // re-detection follows a choice made *here* and not every
                    // other way this value changes — switching profiles in the
                    // sidebar also moves it, and that must not rewrite the
                    // profile being switched to.
                    Picker("", selection: Binding(
                        get: { store.current.scheme },
                        set: { chosen in
                            guard chosen != store.current.scheme else { return }
                            store.binding(\.scheme).wrappedValue = chosen
                            Task { await detect(adopting: true) }
                        },
                    )) {
                        ForEach(detected.schemes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
            }

            Row("Bundle ID") {
                TextField("com.example.app", text: store.binding(\.bundleID))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            Row("Extensions") {
                TextField("optional, comma separated",
                          text: store.binding(\.extensionBundleIDsRaw))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            Row("Platform") {
                Picker("", selection: platformBinding) {
                    ForEach(ShipPlatform.allCases) { platform in
                        Text(platform.displayName).tag(platform)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(runner.isRunning)
                if store.current.platformOverride == nil {
                    Pill(text: "detected", color: .secondary)
                }
                Spacer()
            }

            if !detectionNote.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: detectionWarning
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(detectionWarning ? Design.warning : Design.success)
                    Text(detectionNote)
                        .font(.system(size: 11))
                        .foregroundStyle(detectionWarning ? Design.warning : .secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Offered rather than applied: a typed identifier is a
                    // deliberate choice, and overwriting one silently would be
                    // the same kind of surprise this warning exists to prevent.
                    if detectionWarning, !detected.bundleID.isEmpty,
                       detected.bundleID != store.current.bundleID {
                        Button("Use it") { adoptDetectedIdentifiers() }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                    }
                }
                .padding(.leading, Design.labelWidth + 10)
            }
        }
    }

    private var credentialsCard: some View {
        Card("App Store Connect", symbol: "key.fill") {
            Row("API key (.p8)") {
                pathField(
                    path: store.current.keyPath,
                    prompt: "Choose…",
                    types: [UTType(filenameExtension: "p8") ?? .data],
                    onPick: store.adoptKey(path:),
                )
            }

            Row("Key ID") {
                TextField("ABCDE12345", text: store.binding(\.keyID))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                if store.keyIDLooksWrong {
                    Pill(text: "expects 10 chars", color: Design.warning,
                         symbol: "exclamationmark")
                }
            }

            Row("Issuer ID") {
                TextField("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                          text: store.binding(\.issuerID))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                if !store.knownKeys.isEmpty {
                    Menu {
                        ForEach(store.knownKeys) { key in
                            Button(key.label) { store.applyKnownKey(key) }
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                    .help("Reuse a key from another store")
                }

                if store.issuerLooksWrong {
                    Pill(text: "expects a UUID", color: Design.warning,
                         symbol: "exclamationmark")
                }
            }

            Row("Signing identity") {
                pathField(
                    path: store.current.identityPath,
                    prompt: "Choose .p12…",
                    types: [UTType(filenameExtension: "p12") ?? .data],
                    onPick: { store.binding(\.identityPath).wrappedValue = $0 },
                )
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.success)
                Text("No Apple ID, and nothing kept in the Keychain. Both files stay where you "
                     + "put them — only paths are saved — and signing happens in a keychain "
                     + "deleted after each run. Reusing one identity across every app on the "
                     + "account is what avoids Apple's two-certificate cap.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    private var proxyCard: some View {
        Card("Network", symbol: "network") {
            Toggle(isOn: store.proxyBinding(\.enabled, default: false)) {
                Text("Route App Store Connect traffic through a proxy")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if store.current.proxy.enabled {
                Row("Host") {
                    TextField("gw.example.com", text: store.proxyBinding(\.host, default: ""))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    if !store.knownProxies.isEmpty {
                        Menu {
                            ForEach(store.knownProxies) { known in
                                Button(known.label) { store.applyKnownProxy(known) }
                            }
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 28)
                        .help("Reuse a proxy from another store (new port assigned)")
                    }
                }
                Row("Sticky port") {
                    TextField("10000", value: store.proxyBinding(\.port, default: 0),
                              formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Button("Assign free port") { store.assignStickyPort() }
                        .controlSize(.small)
                    Text("\(ProxyConfig.stickyPortRange.lowerBound)–"
                         + "\(ProxyConfig.stickyPortRange.upperBound)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
                Row("Username") {
                    TextField("optional", text: store.proxyBinding(\.username, default: ""))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                Row("Password") {
                    SecureField("optional", text: store.proxyPasswordBinding())
                        .textFieldStyle(.roundedBorder)
                }
                Row("Session token") {
                    TextField("only if your provider keys sessions on the username",
                              text: store.proxyBinding(\.sessionSuffix, default: ""))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                HStack(spacing: 6) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 11)).foregroundStyle(Design.success)
                    Text("The password is saved in your data file alongside everything else, "
                         + "and is redacted from the build log.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Sticky, never rotating: one port per store means one stable exit IP. "
                         + "A new store inherits the host and credentials but is assigned the "
                         + "next free port, so two stores never share an address. Note a proxy "
                         + "does not stop Apple associating accounts — that is decided by Apple "
                         + "ID sign-ins and device identifiers, which using an API key already "
                         + "avoids.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var testFlightCard: some View {
        Card("TestFlight", symbol: "airplane.departure", accessory: AnyView(
            Button {
                Task { await loadTestFlight() }
            } label: {
                HStack(spacing: 4) {
                    if loadingTestFlight { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                    Text("Refresh").font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            .disabled(loadingTestFlight || store.current.bundleID.isEmpty
                      || store.current.keyPath.isEmpty),
        )) {
            if builds.isEmpty && groups.isEmpty {
                Text(testFlightNote.isEmpty
                     ? "Refresh to see uploaded builds, review status and your share link."
                     : testFlightNote)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(builds.prefix(4)) { build in
                    HStack(spacing: 8) {
                        Text("Build \(build.version)")
                            .font(.system(size: 12, weight: .medium)).frame(width: 78, alignment: .leading)

                        Pill(text: build.processingState.capitalized,
                             color: build.processingState == "VALID" ? Design.success : Design.warning)

                        if build.readyInternally {
                            Pill(text: "Internal ready", color: Design.success,
                                 symbol: "checkmark")
                        }
                        if build.approvedExternally {
                            Pill(text: "Link live", color: Design.success, symbol: "link")
                        } else if build.inReview {
                            Pill(text: "In review", color: Design.warning, symbol: "clock")
                        } else if build.needsReviewSubmission {
                            Pill(text: "Needs review", color: Design.warning,
                                 symbol: "exclamationmark")
                        }

                        Spacer()
                        Text(build.uploaded).font(.system(size: 10)).foregroundStyle(.secondary)

                        if build.needsReviewSubmission && build.processingState == "VALID" {
                            Button("Submit for review") {
                                Task { await submitForReview(build) }
                            }
                            .controlSize(.small)
                            .disabled(loadingTestFlight)
                        }
                    }
                }

                if !groups.isEmpty { Divider().padding(.vertical, 2) }

                ForEach(groups) { group in
                    HStack(spacing: 8) {
                        Image(systemName: group.isInternal ? "lock.fill" : "globe")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(group.name).font(.system(size: 12, weight: .medium))
                        Pill(text: group.isInternal ? "Internal" : "External",
                             color: group.isInternal ? .secondary : Color.accentColor)
                        Text("\(group.testerCount) tester\(group.testerCount == 1 ? "" : "s")")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        if !group.publicLink.isEmpty {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(group.publicLink, forType: .string)
                                copiedLink = true
                                Task {
                                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                                    copiedLink = false
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: copiedLink ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 9))
                                    Text(copiedLink ? "Copied" : "Copy link")
                                        .font(.system(size: 11))
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    if !group.publicLink.isEmpty {
                        Text(group.publicLink)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.leading, 18)
                    }
                }

                if !testFlightNote.isEmpty {
                    Text(testFlightNote).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            if let detail = review {
                Divider().padding(.vertical, 2)

                HStack(spacing: 6) {
                    Image(systemName: "person.text.rectangle")
                        .font(.system(size: 11)).foregroundStyle(Design.accent)
                    Text("Review contact & demo account")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(savingReview ? "Saving…" : "Save to Apple") {
                        Task { await saveReview() }
                    }
                    .controlSize(.small)
                    .disabled(savingReview)
                }

                Row("Contact") {
                    TextField("First", text: store.binding(\.reviewFirstName))
                        .textFieldStyle(.roundedBorder)
                    TextField("Last", text: store.binding(\.reviewLastName))
                        .textFieldStyle(.roundedBorder)
                }
                Row("Email") {
                    TextField("you@example.com", text: store.binding(\.reviewEmail))
                        .textFieldStyle(.roundedBorder)
                }
                Row("Phone") {
                    TextField("+44 7700 900000", text: store.binding(\.reviewPhone))
                        .textFieldStyle(.roundedBorder)
                }

                Toggle(isOn: store.boolBinding(\.demoAccountRequired)) {
                    Text("App requires sign-in (provide a demo account)")
                        .font(.system(size: 12))
                }
                .toggleStyle(.switch).controlSize(.small)

                if store.current.demoAccountRequired {
                    Row("Demo username") {
                        TextField("qa@example.com", text: store.binding(\.demoAccountName))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    Row("Demo password") {
                        SecureField("", text: store.demoPasswordBinding())
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Row("Notes") {
                    TextField("anything the reviewer needs to know",
                              text: store.binding(\.reviewNotes))
                        .textFieldStyle(.roundedBorder)
                }

                Text("Saved with this store, so each client keeps its own contact and demo "
                     + "login. Detail id \(detail.id.prefix(8))…")
                    .font(.system(size: 10)).foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 11)).foregroundStyle(Design.success)
                    Text("A reviewer cannot get past a sign-in screen without working "
                         + "credentials, and the submission is rejected for it. The demo "
                         + "password is kept in the Keychain, never in profiles.json.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Testers install from the link with their own Apple ID — no device UDIDs are "
                 + "collected or registered. Internal testers work as soon as a build finishes "
                 + "processing; a public link additionally needs Beta App Review, once per "
                 + "version.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var releaseCard: some View {
        Card("Release", symbol: "number") {
            HStack(spacing: 10) {
                Text("Version").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: Design.labelWidth, alignment: .leading)
                TextField(detected.marketingVersion.isEmpty ? "1.0" : detected.marketingVersion,
                          text: store.binding(\.marketingVersion))
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                Text("Build").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField(detected.buildNumber.isEmpty ? "1" : detected.buildNumber,
                          text: store.binding(\.buildNumber))
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                Spacer()
            }

            Text("Blank keeps whatever the project sets. Each upload needs a build number "
                 + "higher than the last.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, Design.labelWidth + 10)

            Divider().padding(.vertical, 2)

            Text("Certificates")
                .font(.system(size: 12, weight: .medium))

            Text("Apple caps certificates per account and refuses the next one. This tool "
                 + "cannot reuse existing certificates — their private keys live on the "
                 + "machines that made them — so at the limit it revokes the oldest "
                 + "automatically and retries, naming each one it removes in the log. That "
                 + "breaks signing for anyone still using the revoked certificate.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Run bar

    private var runBar: some View {
        VStack(spacing: 0) {
            if runner.isRunning || runner.finished {
                stageStrip
                Divider()
            }

            HStack(spacing: 12) {
                Picker("", selection: $configuration) {
                    ForEach(Pipeline.Configuration.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .disabled(runner.isRunning)

                if !runner.log.isEmpty {
                    Button {
                        showingLog = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "text.alignleft").font(.system(size: 10))
                            Text("Log").font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()

                if runner.failed {
                    Text(runner.status)
                        .font(.system(size: 11))
                        .foregroundStyle(Design.failure)
                        .lineLimit(2)
                        .frame(maxWidth: 320, alignment: .trailing)
                }

                Button {
                    start(upload: false)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "hammer.fill").font(.system(size: 12))
                        Text("Build IPA").font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.07)),
                )
                // Detection has to land first: it is what says which platform
                // the scheme builds, and a run started before it reports is
                // built from whatever was left in state.
                .disabled(runner.isRunning || detecting)

                PrimaryButton(
                    title: runner.isRunning ? "Working…" : "Build & Upload",
                    symbol: runner.isRunning ? "hourglass" : "arrow.up.circle.fill",
                    enabled: !runner.isRunning && !detecting && configuration == .release,
                ) { start(upload: true) }
                .frame(width: 170)
                .help(detecting ? "Reading the project…"
                      : configuration == .release
                      ? "Archive, sign, validate and upload"
                      : "Only a Release build can be uploaded")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(.regularMaterial)
    }

    /// Live pipeline progress — what is happening now, and what is left.
    private var stageStrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(runner.steps.enumerated()), id: \.element.id) { index, stage in
                let state = runner.state(of: stage)

                HStack(spacing: 7) {
                    ZStack {
                        Circle()
                            .fill(state.tint.opacity(state == .pending ? 0.12 : 0.18))
                            .frame(width: 22, height: 22)
                        if state == .active {
                            ProgressView().controlSize(.small).scaleEffect(0.55)
                        } else {
                            Image(systemName: state == .done ? "checkmark"
                                  : state == .failed ? "xmark" : stage.symbol)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(state.tint)
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text(stage.title)
                            .font(.system(size: 10, weight: state == .active ? .semibold : .regular))
                            .foregroundStyle(state == .pending ? .secondary : .primary)
                        if state == .active {
                            Text(stage.hint)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                if index < runner.steps.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 6)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.2), value: runner.currentStage)
    }

    private var logSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Build log").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.fullLog, forType: .string)
                }
                Button("Done") { showingLog = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.log.isEmpty ? "Nothing yet." : runner.log)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("bottom")
                }
                .onChange(of: runner.log) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .frame(width: 760, height: 520)
    }

    // MARK: - Actions

    /// Read the project and reconcile the profile with what it builds.
    ///
    /// `adopting` marks the cases where the thing being built actually changed
    /// — a different project chosen, or a different scheme picked. Every
    /// identifier the profile holds then describes what came before, and
    /// keeping it is never right: that is precisely what produced an .ipa built
    /// from one app's source and signed for another's bundle id.
    private func detect(adopting: Bool = false) async {
        var path = store.current.projectPath
        guard !path.isEmpty, !detecting else { return }

        detecting = true
        detectionNote = "Reading project…"
        defer { detecting = false }

        // Self-heal a stored path that points at a broken or renamed project,
        // so detection and the build read what actually opens.
        if let resolved = ProjectInspector.resolveProject(at: path), resolved != path {
            store.binding(\.projectPath).wrappedValue = resolved
            path = resolved
        }

        let (schemes, _) = await ProjectInspector.list(projectPath: path)
        guard !schemes.isEmpty else {
            detected = ProjectInspector.Info()
            detectionWarning = true
            detectionNote = "No schemes found. Is that a valid project with a shared scheme?"
            return
        }

        // Keep the chosen scheme if it is still valid, so re-detecting is not
        // a reset of the user's decision.
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

        if adopting, !info.bundleID.isEmpty {
            // Replace, rather than fill. Guarded on having actually read
            // something: a project that could not be parsed is no reason to
            // throw away identifiers that may still be correct.
            adoptDetectedIdentifiers()
        } else {
            // Fill blanks only. A typed value is a deliberate choice.
            if store.current.bundleID.isEmpty, !info.bundleID.isEmpty {
                store.binding(\.bundleID).wrappedValue = info.bundleID
            }
            if store.current.extensionBundleIDsRaw.isEmpty, !info.extensionBundleIDs.isEmpty {
                store.binding(\.extensionBundleIDsRaw).wrappedValue =
                    info.extensionBundleIDs.joined(separator: ", ")
            }
        }

        // A stored identifier that contradicts the project is almost always
        // left over from another app: pointing an existing profile at a new
        // project keeps the old bundle id, and nothing later objects. Export
        // signs without a profile, and the first complaint is Apple's 90174 —
        // after a full build, and after App IDs and profiles have been
        // registered for an app that was never being built.
        detectionWarning = false
        if !info.bundleID.isEmpty, !store.current.bundleID.isEmpty,
           info.bundleID != store.current.bundleID {
            detectionWarning = true
            detectionNote = "Scheme \(scheme) builds \(info.bundleID), not \(store.current.bundleID)."
        } else if let stray = store.current.extensionBundleIDs.first(where: {
            !info.extensionBundleIDs.contains($0)
        }) {
            detectionWarning = true
            detectionNote = "\(stray) is listed under Extensions, but this scheme does not build it."
        } else {
            detectionNote = "Detected \(info.summary)"
        }
    }

    /// Replace the stored identifiers with the ones the project actually builds.
    private func adoptDetectedIdentifiers() {
        guard !detected.bundleID.isEmpty else { return }
        store.binding(\.bundleID).wrappedValue = detected.bundleID
        store.binding(\.extensionBundleIDsRaw).wrappedValue =
            detected.extensionBundleIDs.joined(separator: ", ")
        detectionWarning = false
        detectionNote = "Detected \(detected.summary)"
    }

    private func client() -> ASCClient {
        let p = store.current
        return ASCClient(keyID: p.keyID, issuerID: p.issuerID,
                         privateKeyPath: p.keyPath,
                         proxyDictionary: p.proxy.sessionProxyDictionary)
    }

    private func loadTestFlight() async {
        guard !loadingTestFlight else { return }
        loadingTestFlight = true
        testFlightNote = ""
        defer { loadingTestFlight = false }

        do {
            let api = client()
            let appID = try await api.appID(bundleID: store.current.bundleID)
            builds = try await api.builds(appID: appID)
            groups = try await api.betaGroups(appID: appID)
            if builds.isEmpty { testFlightNote = "No builds uploaded yet." }

            // Contact and demo details live on the app, not on a build, so they
            // are fetched once here and can be filled in before any submission.
            review = try? await api.reviewDetail(appID: appID)
            // Seed the store from Apple the first time only; after that the
            // local values are what the user edits and what gets pushed.
            if let detail = review, store.current.reviewEmail.isEmpty {
                store.binding(\.reviewFirstName).wrappedValue = detail.contactFirstName
                store.binding(\.reviewLastName).wrappedValue = detail.contactLastName
                store.binding(\.reviewEmail).wrappedValue = detail.contactEmail
                store.binding(\.reviewPhone).wrappedValue = detail.contactPhone
                store.binding(\.demoAccountName).wrappedValue = detail.demoAccountName
                store.boolBinding(\.demoAccountRequired).wrappedValue = detail.demoAccountRequired
                store.binding(\.reviewNotes).wrappedValue = detail.notes
            }
        } catch {
            builds = []; groups = []
            testFlightNote = error.localizedDescription
        }
    }

    private func saveReview() async {
        guard let existing = review else { return }
        savingReview = true
        defer { savingReview = false }

        // Built from the store, so what Apple receives is exactly what is on
        // screen for this client.
        let p = store.current
        var detail = existing
        detail.contactFirstName = p.reviewFirstName
        detail.contactLastName = p.reviewLastName
        detail.contactEmail = p.reviewEmail
        detail.contactPhone = p.reviewPhone
        detail.demoAccountName = p.demoAccountName
        detail.demoAccountRequired = p.demoAccountRequired
        detail.notes = p.reviewNotes

        do {
            try await client().updateReviewDetail(
                detail, demoPassword: SecretStore.shared.get(p.demoPasswordKey))
            store.save()
            testFlightNote = "Review contact and demo details saved to App Store Connect."
        } catch {
            testFlightNote = error.localizedDescription
        }
    }

    private func submitForReview(_ build: ASCClient.BuildInfo) async {
        loadingTestFlight = true
        defer { loadingTestFlight = false }
        do {
            try await client().submitForBetaReview(buildID: build.id)
            testFlightNote = "Submitted build \(build.version) for Beta App Review. "
                + "Usually under 24 hours; the link goes live once it passes."
            await loadTestFlight()
        } catch {
            // Missing review contact details are the usual cause, and Apple
            // says so in the error — so show it rather than paraphrasing.
            testFlightNote = error.localizedDescription
        }
    }

    /// The platform this run ships as: the user's explicit choice, else what the
    /// project detected. A scheme building both a Mac and an iPhone app under one
    /// bundle id detects as a single platform, so the override reaches the other.
    private var selectedPlatform: ShipPlatform {
        store.current.shipPlatform(detected: detected.platform)
    }

    /// Writes the segmented picker's choice back to the profile as an explicit
    /// override, so it persists and the other platform can be shipped next time.
    private var platformBinding: Binding<ShipPlatform> {
        Binding(
            get: { selectedPlatform },
            set: { store.binding(\.platformRaw).wrappedValue = $0.rawValue },
        )
    }

    private func start(upload: Bool) {
        let problems = store.problems()
        guard problems.isEmpty else {
            runner.fail(problems.joined(separator: " · "),
                        detail: "Before starting:\n" + problems.map { "  • \($0)" }.joined(separator: "\n"))
            return
        }
        store.markUsed()
        store.save()

        // Remember a freshly created identity, so every later build — and
        // every other app on this account — reuses it instead of asking Apple
        // for another certificate.
        runner.onIdentityCreated = { path in
            store.binding(\.identityPath).wrappedValue = path
        }

        runner.run(
            input: Pipeline.Input(
                profile: store.current,
                configuration: configuration,
                platform: selectedPlatform,
                entitlementsByBundleID: detected.entitlements,
            ),
            upload: upload,
        )
    }

    // MARK: - Pieces

    private func pathField(
        path: String,
        prompt: String,
        types: [UTType],
        onPick: @escaping (String) -> Void,
    ) -> some View {
        PathField(path: path, prompt: prompt, types: types, onPick: onPick)
    }
}

/// A chosen-file row: shows the current path, offers a "Choose…" panel, and
/// also accepts a file dragged onto it. Both routes call `onPick` with a plain
/// path, and the pipeline hands that exact path to the tools (`--p8-file-path`
/// for the key, the project path, the identity) — so the file can live in any
/// folder the user likes, picked or dropped, with nothing copied into a
/// privileged location.
struct PathField: View {
    let path: String
    let prompt: String
    let types: [UTType]
    let onPick: (String) -> Void

    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: path.isEmpty ? "questionmark.folder" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(path.isEmpty ? .secondary : Design.success)
                Text(path.isEmpty ? "Not chosen" : (path as NSString).lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.05)),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isTargeted ? 1.5 : 0),
            )

            Button(prompt) {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = types
                panel.canChooseDirectories = true
                panel.canChooseFiles = true
                panel.allowsMultipleSelection = false
                panel.showsHiddenFiles = true   // .p8 keys live in dot-directories
                if panel.runModal() == .OK, let url = panel.url { onPick(url.path) }
            }
            .controlSize(.small)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.isFileURL && accepts($0) }) else { return false }
            onPick(url.path)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    /// Only adopt a drop whose extension this field actually asks for, so a
    /// stray file dragged onto the key row cannot silently be taken as the key.
    /// This mirrors the panel's `allowedContentTypes`; the generic `.data` /
    /// `.directory` fallbacks the caller passes when a UTType is unavailable
    /// accept anything, exactly as the panel would.
    private func accepts(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return types.contains { type in
            if let want = type.preferredFilenameExtension?.lowercased() { return want == ext }
            return type == .data || type == .directory
        }
    }
}

// MARK: - Runner

@MainActor
final class Runner: ObservableObject {
    enum StageState {
        case pending, active, done, failed

        var tint: Color {
            switch self {
            case .pending: .secondary
            case .active: Color.accentColor
            case .done: Design.success
            case .failed: Design.failure
            }
        }
    }

    @Published private(set) var log = ""
    @Published private(set) var status = "Ready"
    @Published private(set) var isRunning = false
    @Published private(set) var failed = false
    @Published private(set) var finished = false
    @Published private(set) var currentStage: Pipeline.Stage?
    @Published private(set) var steps: [Pipeline.Stage] = []

    private var completed: Set<Pipeline.Stage> = []
    private var task: Task<Void, Never>?

    /// The complete log, accumulated off the render path. What Copy writes to
    /// the pasteboard, and deliberately never bound to a view: a full archive
    /// log is far larger than a single SwiftUI `Text` can lay out, and appending
    /// it to a `@Published` string per output chunk re-rendered the whole window
    /// on every line of a multi-thousand-line build and locked it up. `log`
    /// above holds only the recent tail, refreshed a few times a second.
    private let logStore = Locked("")
    var fullLog: String { logStore.value }

    /// Copies the buffered tail into `log` on a throttle while a run is active.
    private var flushTask: Task<Void, Never>?

    /// A readable tail of a log, bounded so the view stays light however long
    /// the build ran. The whole log is still available through `fullLog`.
    private static func tail(of text: String, limit: Int = 16_000) -> String {
        guard text.count > limit else { return text }
        let clipped = text.suffix(limit)
        if let newline = clipped.firstIndex(of: "\n") {
            return "… earlier output trimmed — press Copy for the full log …\n"
                + clipped[clipped.index(after: newline)...]
        }
        return "…\n" + clipped
    }

    func state(of stage: Pipeline.Stage) -> StageState {
        if completed.contains(stage) { return .done }
        if currentStage == stage { return failed ? .failed : .active }
        return .pending
    }

    func fail(_ short: String, detail: String) {
        failed = true
        finished = true
        steps = []
        status = short
        logStore.mutate { $0 = detail + "\n" }
        log = Self.tail(of: detail + "\n")
    }

    /// Set when a run creates a signing identity, so the view can store its
    /// path against the profile.
    var onIdentityCreated: ((String) -> Void)?

    func run(input: Pipeline.Input, upload: Bool) {
        guard !isRunning else { return }
        isRunning = true
        failed = false
        finished = false
        logStore.mutate { $0 = "" }
        log = ""
        completed = []
        currentStage = nil
        steps = Pipeline.Stage.steps(upload: upload)
        status = upload ? "Building and uploading…" : "Building…"

        // Accumulate output off the main thread; a throttled task copies a
        // bounded tail into `log` a few times a second. Appending per chunk to a
        // @Published property instead re-rendered the window on every line of a
        // multi-thousand-line archive and froze it.
        let store = logStore
        let append: @Sendable (String) -> Void = { text in
            store.mutate { $0 += text }
        }
        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let self else { return }
                let tail = Self.tail(of: store.value)
                if tail != self.log { self.log = tail }
            }
        }

        let stage: @Sendable (Pipeline.Stage) -> Void = { [weak self] next in
            Task { @MainActor in
                guard let self else { return }
                // Everything before the new stage is, by definition, finished.
                if let previous = self.currentStage { self.completed.insert(previous) }
                self.currentStage = next
            }
        }

        task = Task {
            var pipeline = Pipeline(input: input, log: append)
            pipeline.onStage = stage
            pipeline.onIdentityCreated = { [weak self] path in
                Task { @MainActor in self?.onIdentityCreated?(path) }
            }
            do {
                if upload {
                    try await pipeline.shipToAppStore()
                    if let last = currentStage { completed.insert(last) }
                    currentStage = nil
                    status = "Uploaded to App Store Connect"
                } else {
                    let ipa = try await pipeline.buildIPA()
                    if let last = currentStage { completed.insert(last) }
                    currentStage = nil
                    status = "Built"
                    append("\n✅ \(ipa)\n")
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ipa)])
                }
            } catch {
                failed = true
                status = error.localizedDescription
                append("\n❌ \(error.localizedDescription)\n")
                // Record the failure so it can be read back — and fixed — from
                // any machine, not just the one that produced it.
                ErrorLog.record(input: input, stage: currentStage, error: error, log: store.value)
            }
            finished = true
            isRunning = false
            flushTask?.cancel()
            log = Self.tail(of: store.value)   // final flush, so the last lines land
        }
    }
}
