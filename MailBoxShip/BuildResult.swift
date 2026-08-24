import SwiftUI
import AppKit

/// What a finished run left behind, and where it went.
///
/// A build that succeeds and then cannot be found is only half a result. The
/// artifact lands in `~/Developer/MailBoxShip`, which is not a folder anyone
/// opens by habit, and the one line naming it scrolls away with the rest of a
/// multi-thousand-line archive log. Holding the path here lets the finish state
/// hand it over directly instead.
struct BuildResult: Equatable {
    /// Absolute path of the `.ipa` (or `.pkg`) the run produced.
    let path: String
    /// Whether it also reached App Store Connect.
    let uploaded: Bool
    /// Read once, when the run finished. A view body is not the place for a
    /// filesystem probe, and a finished artifact does not change size.
    let size: String

    init(path: String, uploaded: Bool) {
        self.path = path
        self.uploaded = uploaded
        let bytes = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64
        self.size = (bytes ?? nil).map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? ""
    }

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var folder: URL { url.deletingLastPathComponent() }

    /// `~/Developer/MailBoxShip/Craftly/Release` — the home prefix abbreviated,
    /// because the literal `/Users/…` is longer and says less.
    var folderDisplay: String { (folder.path as NSString).abbreviatingWithTildeInPath }

    /// Select it in Finder rather than open it: an `.ipa` has no opener, and
    /// double-clicking one does nothing worth watching.
    func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

/// The folder every finished build is filed into.
enum Builds {
    static var root: URL { Pipeline.outputRoot }

    /// Opens the folder, creating it first so the button always lands
    /// somewhere. An alert saying it does not exist yet teaches nothing; an
    /// empty folder at the right path teaches where to look.
    static func open() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    static func openAppStoreConnect() {
        guard let url = URL(string: "https://appstoreconnect.apple.com/apps") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The finish state: what was produced, where it is, and every way to get to it.
///
/// Deliberately the loudest thing on screen once a run ends — a green tick in a
/// status line is a fact, but the question a person actually has at that moment
/// is "where is it", and that deserves buttons rather than a path to retype.
struct ResultCard: View {
    let result: BuildResult
    /// The run bar version: one row, same actions, no card chrome.
    var compact = false

    @State private var copied = false
    @State private var missing = false

    private var title: String {
        result.uploaded ? "Uploaded to App Store Connect" : "Build ready"
    }
    private var symbol: String {
        result.uploaded ? "checkmark.icloud.fill" : "shippingbox.fill"
    }

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        // The file is only checked when the result changes, not per render.
        .task(id: result.path) {
            missing = !FileManager.default.fileExists(atPath: result.path)
        }
    }

    // MARK: - Layouts

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 11) {
                badge
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        if !result.size.isEmpty {
                            Pill(text: result.size, color: .secondary)
                        }
                    }
                    fileName
                    Text(missing ? "No longer at \(result.folderDisplay)" : result.folderDisplay)
                        .font(.system(size: 10))
                        .foregroundStyle(missing ? Design.warning : .secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            WrapChips(spacing: 8) { buttons }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
                .fill(Design.success.opacity(0.07)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
                .strokeBorder(Design.success.opacity(0.28), lineWidth: 1),
        )
    }

    private var compactBody: some View {
        HStack(spacing: 11) {
            badge
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    if !result.size.isEmpty {
                        Text(result.size).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                fileName
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { buttons }.layoutPriority(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.success.opacity(0.08))
    }

    // MARK: - Pieces

    private var badge: some View {
        ZStack {
            Circle().fill(Design.success.opacity(0.16)).frame(width: 30, height: 30)
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Design.success)
        }
    }

    private var fileName: some View {
        Text(result.name)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(result.path)
    }

    @ViewBuilder private var buttons: some View {
        ActionButton(title: "Show in Finder", symbol: "folder.fill",
                     tint: Design.success, prominent: true, enabled: !missing) {
            result.reveal()
        }
        .help(result.path)

        ActionButton(title: copied ? "Copied" : "Copy Path",
                     symbol: copied ? "checkmark" : "doc.on.doc") {
            result.copyPath()
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        }
        .help("Copy the full path, for a terminal or a message")

        // Not in the run bar: the screen it sits on carries the same button in
        // its header, and the row has a file name to fit as well.
        if !compact {
            ActionButton(title: "All Builds", symbol: "tray.full") { Builds.open() }
                .help("Every build this tool has produced, filed by scheme and configuration")
        }

        if result.uploaded {
            ActionButton(title: "App Store Connect", symbol: "safari") {
                Builds.openAppStoreConnect()
            }
            .help("Open App Store Connect in your browser")
        }
    }
}
