import Foundation

/// Runs command-line tools and streams their output back live.
///
/// Streaming rather than collecting matters here: an archive takes minutes,
/// and a progress window that shows nothing until it finishes is
/// indistinguishable from one that has hung.
enum Shell {

    struct Result {
        let status: Int32
        let output: String
        var succeeded: Bool { status == 0 }
    }

    /// Xcode's location, resolved without touching `xcode-select`.
    ///
    /// `xcode-select -s` is system-wide, needs sudo, and changes behaviour for
    /// every other tool on the machine. Setting DEVELOPER_DIR per invocation
    /// achieves the same thing for this process only.
    static var developerDir: String {
        let candidates = [
            "/Applications/Xcode.app/Contents/Developer",
            "/Applications/Xcode-beta.app/Contents/Developer",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? "/Applications/Xcode.app/Contents/Developer"
    }

    @discardableResult
    static func run(
        _ launchPath: String,
        _ arguments: [String],
        environment extra: [String: String] = [:],
        currentDirectory: String? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil,
    ) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments

            var env = ProcessInfo.processInfo.environment
            env["DEVELOPER_DIR"] = developerDir
            // Homebrew is not on PATH for a GUI-launched app.
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
            extra.forEach { env[$0.key] = $0.value }
            process.environment = env

            if let currentDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
            }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let collected = Locked("")
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                collected.mutate { $0 += text }
                onOutput?(text)
            }

            process.terminationHandler = { proc in
                // Drain whatever landed between the last read and exit.
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty, let text = String(data: rest, encoding: .utf8) {
                    collected.mutate { $0 += text }
                    onOutput?(text)
                }
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(
                    returning: Result(status: proc.terminationStatus, output: collected.value),
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(
                    returning: Result(status: -1, output: "Could not run \(launchPath): \(error)"),
                )
            }
        }
    }
}

/// Minimal mutex box. The pipe handler fires on an arbitrary queue, so the
/// accumulating buffer needs guarding.
final class Locked<T>: @unchecked Sendable {
    private var storage: T
    private let lock = NSLock()

    init(_ value: T) { storage = value }

    var value: T {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&storage)
    }
}
