import SwiftUI
import AppKit

/// Cross-machine sync: an anonymous Firebase identity, Push and Pull of the one
/// data document, and a pairing code to bring another Mac onto the same identity.
struct SyncView: View {
    @ObservedObject var sync: SyncStore
    @Environment(\.dismiss) private var dismiss

    @State private var pairCode = ""
    @State private var redeemField = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if !sync.available {
                Text("Sync is off because no Firebase project is configured in Deployment.swift.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                pushPull
                Divider()
                pairing
            }

            if !sync.status.isEmpty {
                HStack(spacing: 6) {
                    if sync.busy { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    Text(sync.status)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(width: 470)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 18)).foregroundStyle(Design.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sync across Macs").font(.system(size: 15, weight: .semibold))
                Text(sync.signedIn ? "Identity \(sync.uid.prefix(10))…" : "Not signed in yet")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    private var pushPull: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { sync.pushNow() } label: {
                    Label("Push", systemImage: "icloud.and.arrow.up").frame(maxWidth: .infinity)
                }
                Button { sync.pullNow() } label: {
                    Label("Pull", systemImage: "icloud.and.arrow.down").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
            .disabled(sync.busy)

            Text("Push uploads your profiles, the .p8/.p12 key files and the error log. "
                 + "Pull rewrites this Mac's data with what's in the cloud.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair another Mac").font(.system(size: 12, weight: .semibold))

            HStack(spacing: 8) {
                Button("Show this Mac's code") {
                    Task { pairCode = await sync.pairingCode() ?? "" }
                }
                .controlSize(.small)
                .disabled(sync.busy)

                if !pairCode.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pairCode, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)
                }
            }

            if !pairCode.isEmpty {
                Text(pairCode)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Text("On the other Mac, paste that code below and press Pair — it joins this "
                 + "identity and pulls everything.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Paste a pairing code…", text: $redeemField)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("Pair") { sync.redeem(pairingCode: redeemField); redeemField = "" }
                    .disabled(sync.busy || redeemField.isEmpty)
            }
        }
    }
}
