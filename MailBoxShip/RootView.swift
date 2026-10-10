import SwiftUI

/// Owns the one store and the run pool, and chooses which face to show.
///
/// Both screens are views over the *same* `ProfileStore` and `RunCenter`, so
/// flipping between them keeps the selected client and every run in flight —
/// "Advanced" is a different lens on the current state, not a different app.
///
/// Each screen is handed the runner of the profile on screen. Selecting
/// another profile hands over that one's runner instead, so a run carries on
/// in the background — still visible in the profile list — while the next app
/// is set up and started beside it.
struct RootView: View {
    @StateObject private var store = ProfileStore()
    @StateObject private var runs = RunCenter()
    @StateObject private var sync = SyncStore()

    /// Defaults to the simple screen; remembered per user thereafter.
    @AppStorage("simpleMode") private var simpleMode = true

    var body: some View {
        let runner = runs.runner(for: store.selectedID)
        Group {
            if simpleMode {
                SimpleView(store: store, runner: runner, runs: runs, sync: sync) {
                    withAnimation(.easeInOut(duration: 0.15)) { simpleMode = false }
                }
                .frame(minWidth: 640, minHeight: 620)
            } else {
                AdvancedView(store: store, runner: runner, runs: runs, sync: sync) {
                    withAnimation(.easeInOut(duration: 0.15)) { simpleMode = true }
                }
                .frame(minWidth: 900, minHeight: 640)
            }
        }
        // A pull rewrites the data file underneath us; reload the profile list.
        .onAppear { sync.onDidPull = { store.reload() } }
    }
}
