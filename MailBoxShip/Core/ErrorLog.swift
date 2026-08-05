import Foundation

/// A markdown record of failed runs, kept beside the ship data file.
///
/// A build that fails on one Mac is often diagnosed from another — a different
/// machine, sometimes a different person. Writing each failure to a plain
/// markdown file next to `ship.json` (so it travels with the data, and once
/// cloud sync is on, syncs with it) means the failure can be read back and
/// fixed without the terminal that produced it. Newest entry first; capped so
/// it cannot grow without bound.
enum ErrorLog {

    private static let title = "# MailBoxShip errors\n\n"
    /// Rough ceiling. Entries are prepended, so trimming to this size drops the
    /// oldest — which is exactly what a log of recent failures wants.
    private static let maxBytes = 200_000

    /// `ship-errors.md`, in the same folder as the data file.
    static func path(folder: String) -> String {
        (folder as NSString).appendingPathComponent("ship-errors.md")
    }

    /// Append a record of one failed run. Best-effort: a failure to write the
    /// log must never mask the build failure that triggered it.
    @MainActor
    static func record(input: Pipeline.Input, stage: Pipeline.Stage?, error: Error, log: String) {
        let folder = SecretStore.shared.folder
        let entry = format(input: input, stage: stage, error: error, log: log)
        write(prepending: entry, folder: folder)
    }

    // MARK: - Formatting

    private static func format(
        input: Pipeline.Input, stage: Pipeline.Stage?, error: Error, log: String,
    ) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let when = stamp.string(from: Date())

        let app = input.scheme.isEmpty ? input.bundleID : input.scheme
        let failedAt = stage?.title ?? "before the first stage"
        let message = (error as? ShipError)?.message ?? error.localizedDescription

        let version = input.marketingVersion.isEmpty ? "project default" : input.marketingVersion
        let build = input.buildNumber.isEmpty ? "project default" : input.buildNumber

        return """
        ## \(when) — \(app) — failed at \(failedAt)

        - **Bundle ID:** `\(input.bundleID.isEmpty ? "—" : input.bundleID)`
        - **Scheme:** `\(input.scheme.isEmpty ? "—" : input.scheme)`
        - **Project:** `\(input.projectPath.isEmpty ? "—" : input.projectPath)`
        - **Version (build):** \(version) (\(build))
        - **Stage:** \(failedAt)
        - **Error:** \(message)

        <details><summary>Log tail</summary>

        ```
        \(logTail(log))
        ```

        </details>

        ---


        """
    }

    /// The last slice of the run log — enough to diagnose, bounded so one long
    /// archive cannot dominate the file.
    private static func logTail(_ log: String, limit: Int = 6_000) -> String {
        let trimmed = log.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(no output captured)" }
        guard trimmed.count > limit else { return trimmed }
        return "… earlier output trimmed …\n" + String(trimmed.suffix(limit))
    }

    // MARK: - Persistence

    private static func write(prepending entry: String, folder: String) {
        let file = path(folder: folder)
        try? FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true)

        let existing = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let history = existing.hasPrefix(title) ? String(existing.dropFirst(title.count)) : existing

        var combined = title + entry + history
        // Keep the newest; trim the oldest tail if over the ceiling. A cut in
        // the middle of an old entry is acceptable for a log.
        if combined.utf8.count > maxBytes {
            combined = String(combined.prefix(maxBytes))
        }

        try? combined.write(toFile: file, atomically: true, encoding: .utf8)
        // Owner-only, matching the data file it sits beside.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }
}
