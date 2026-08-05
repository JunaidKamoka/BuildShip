import SwiftUI

/// Owns the one store and the one runner, and chooses which face to show.
///
/// Both screens are views over the *same* `ProfileStore` and `Runner`, so
/// flipping between them keeps the selected client and any run in flight —
/// "Advanced" is a different lens on the current state, not a different app.
struct RootView: View {
    @StateObject private var store = ProfileStore()
    @StateObject private var runner = Runner()
    @StateObject private var sync = SyncStore()

    /// Defaults to the simple screen; remembered per user thereafter.
    @AppStorage("simpleMode") private var simpleMode = true

    var body: some View {
        Group {
            if simpleMode {
                SimpleView(store: store, runner: runner, sync: sync) {
                    withAnimation(.easeInOut(duration: 0.15)) { simpleMode = false }
                }
                .frame(minWidth: 640, minHeight: 620)
            } else {
                AdvancedView(store: store, runner: runner, sync: sync) {
                    withAnimation(.easeInOut(duration: 0.15)) { simpleMode = true }
                }
                .frame(minWidth: 900, minHeight: 640)
            }
        }
        // A pull rewrites the data file underneath us; reload the profile list.
        .onAppear { sync.onDidPull = { store.reload() } }
    }
}
