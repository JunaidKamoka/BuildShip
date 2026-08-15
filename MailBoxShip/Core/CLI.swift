import Foundation

/// Headless entry point: `MailBoxShip --ship [profile] [--build-only]`.
///
/// Runs the same `Pipeline` the window drives, against the same saved data, so
/// what is exercised here is the shipping code rather than a parallel
/// implementation that could drift from it. That also makes the tool usable
/// from a script or CI without a GUI session.
enum CLI {

    /// Unbuffered, so progress is visible while a long archive runs rather
    /// than arriving in one lump at the end.
    private static func say(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static var shouldRun: Bool {
        CommandLine.arguments.contains("--ship")
    }

    /// Never returns — exits the process when the run finishes.
    static func run() -> Never {
        let arguments = CommandLine.arguments
        let uploadRequested = !arguments.contains("--build-only")

        // First bare argument after --ship names the profile.
        let named = arguments.drop(while: { $0 != "--ship" }).dropFirst()
            .first(where: { !$0.hasPrefix("--") })

        // The work is main-actor isolated (the stores are), so the main thread
        // must stay free to run it. Blocking here on a semaphore deadlocks:
        // the task can never be scheduled on the actor it needs. Spin the run
        // loop instead and exit from inside the task.
        Task { @MainActor in
            let store = ProfileStore()
            guard let profile = named.flatMap({ name in
                store.profiles.first { $0.name == name }
            }) ?? store.profiles.sorted(by: { $0.lastUsed > $1.lastUsed }).first else {
                FileHandle.standardError.write(Data("No profiles configured.\n".utf8))
                exit(2)
            }

            let problems = { () -> [String] in
                store.selectedID = profile.id
                return store.problems()
            }()
            guard problems.isEmpty else {
                FileHandle.standardError.write(
                    Data(("Not ready:\n" + problems.map { "  • \($0)" }
                        .joined(separator: "\n") + "\n").utf8))
                exit(2)
            }

            say("Profile: \(profile.name)  (\(profile.bundleID))\n")
            say("Mode:    \(uploadRequested ? "build + upload" : "build only")\n\n")

            // Detection fills in the entitlements map, which is what lets each
            // App ID get exactly the capabilities its own target declares.
            let (schemes, _) = await ProjectInspector.list(projectPath: profile.projectPath)
            let scheme = schemes.contains(profile.scheme) ? profile.scheme
                : (schemes.first ?? profile.scheme)
            let detected = await ProjectInspector.inspect(
                projectPath: profile.projectPath, scheme: scheme)

            let input = Pipeline.Input(
                projectPath: profile.projectPath,
                scheme: scheme,
                configuration: .release,
                // The CLI always reads the project first, so detection is the
                // authority here; the saved choice only covers a project that
                // could not be read at all.
                platform: detected.platform ?? profile.detectedPlatform ?? profile.platformOverride ?? .iOS,
                bundleID: profile.bundleID,
                extensionBundleIDs: profile.extensionBundleIDs,
                keyPath: profile.keyPath,
                keyID: profile.keyID,
                issuerID: profile.issuerID,
                marketingVersion: profile.marketingVersion,
                buildNumber: profile.buildNumber,
                entitlementsByBundleID: detected.entitlements,
                proxyDictionary: profile.proxy.sessionProxyDictionary,
                proxyEnvironment: profile.proxy.toolEnvironment,
                proxyDescription: profile.proxy.redactedDescription,
                identityPath: profile.identityPath,
            )

            // Buffer the log and remember the last stage, so a failure can be
            // recorded to ship-errors.md exactly as the window does.
            let logBuffer = Locked("")
            let lastStage = Locked<Pipeline.Stage?>(nil)

            var pipeline = Pipeline(input: input, log: { text in
                FileHandle.standardOutput.write(Data(text.utf8))
                logBuffer.mutate { $0 += text }
            })
            pipeline.onStage = { stage in
                lastStage.mutate { $0 = stage }
                FileHandle.standardOutput.write(Data("\n[\(stage.title)]\n".utf8))
            }
            // Remember a newly created identity, exactly as the window does.
            pipeline.onIdentityCreated = { path in
                Task { @MainActor in
                    guard let index = store.profiles.firstIndex(where: { $0.id == profile.id })
                    else { return }
                    store.profiles[index].identityPath = path
                    store.save()
                }
            }

            do {
                if uploadRequested {
                    try await pipeline.shipToAppStore()
                    say("\n✅ Uploaded.\n")
                } else {
                    let ipa = try await pipeline.buildIPA()
                    say("\n✅ \(ipa)\n")
                }
            } catch {
                ErrorLog.record(
                    input: input, stage: lastStage.value, error: error, log: logBuffer.value)
                FileHandle.standardError.write(
                    Data("\n❌ \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            exit(0)
        }

        RunLoop.main.run()
        exit(0)
    }
}
