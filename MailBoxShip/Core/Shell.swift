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
            let reader = pipe.fileHandleForReading

            // Each read is appended in the same critical section that made it.
            // The handler runs on an arbitrary queue, so a chunk read outside
            // the lock could be appended after the final drain, splicing the
            // output at a chunk boundary. That once split
            // "Payload/PrinterApp.app/…" into "Payload/PrinterA" and "pp.app/…".
            let capture = Locked(Capture())
            reader.readabilityHandler = { handle in
                capture.mutate { $0.take(handle.availableData, streamingTo: onOutput) }
            }

            process.terminationHandler = { proc in
                // Stop the handler, then drain under the lock it reads under:
                // a chunk it has already read is appended before the drain,
                // and a call still queued finds the pipe at end of file.
                reader.readabilityHandler = nil
                var output = ""
                capture.mutate {
                    $0.take(reader.readDataToEndOfFile(), streamingTo: onOutput)
                    $0.finishStream(to: onOutput)
                    output = String(decoding: $0.bytes, as: UTF8.self)
                }
                continuation.resume(
                    returning: Result(status: proc.terminationStatus, output: output),
                )
            }

            do {
                try process.run()
            } catch {
                reader.readabilityHandler = nil
                continuation.resume(
                    returning: Result(status: -1, output: "Could not run \(launchPath): \(error)"),
                )
            }
        }
    }

    /// A run's output as raw bytes, decoded only once it is complete.
    ///
    /// A pipe read can stop partway through a multi-byte UTF-8 character, and
    /// decoding such a chunk on its own fails outright: the old per-chunk
    /// `String(data:encoding:)` returned nil and dropped the whole chunk.
    private struct Capture {
        private(set) var bytes = Data()
        /// The tail of the last chunk, when it stopped partway through a
        /// character, held back from the live stream until the rest arrives.
        private var unstreamed = Data()

        mutating func take(_ chunk: Data, streamingTo onOutput: ((String) -> Void)?) {
            guard !chunk.isEmpty else { return }
            bytes.append(chunk)
            guard let onOutput else { return }
            let pending = unstreamed + chunk
            let complete = Shell.completeUTF8Prefix(of: pending)
            unstreamed = pending.suffix(from: pending.startIndex + complete)
            if complete > 0 {
                onOutput(String(decoding: pending.prefix(complete), as: UTF8.self))
            }
        }

        /// Sends whatever was held back, decoded leniently: the output ended,
        /// so the rest of that character is never coming.
        mutating func finishStream(to onOutput: ((String) -> Void)?) {
            guard !unstreamed.isEmpty else { return }
            onOutput?(String(decoding: unstreamed, as: UTF8.self))
            unstreamed = Data()
        }
    }

    /// How many leading bytes of `data` end on a UTF-8 character boundary.
    ///
    /// A character is at most four bytes, so only a lead byte among the last
    /// three can begin one that is still incomplete. Bytes that are invalid
    /// anyway count as complete, so they reach the stream as U+FFFD rather
    /// than holding it up.
    static func completeUTF8Prefix(of data: Data) -> Int {
        let count = data.count
        var back = 1
        while back <= min(3, count) {
            let byte = data[data.startIndex + count - back]
            // A continuation byte (10xxxxxx): keep looking for the lead byte.
            if byte & 0b1100_0000 == 0b1000_0000 {
                back += 1
                continue
            }
            let length = switch byte {
            case 0xC2...0xDF: 2
            case 0xE0...0xEF: 3
            case 0xF0...0xF4: 4
            default: 1 // ASCII, or a byte no valid character starts with.
            }
            return back < length ? count - back : count
        }
        return count
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
