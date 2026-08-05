import SwiftUI

@main
struct MailBoxShipApp: App {
    init() {
        // Headless run, before any window exists. Same Pipeline as the UI, so
        // this cannot drift from what the buttons do.
        if CLI.shouldRun { CLI.run() }
    }

    var body: some Scene {
        WindowGroup("Ship") {
            RootView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Nothing here creates or opens documents.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
