import Foundation

/// A first-come, first-served lock that suspends rather than blocks.
///
/// An actor on its own does not serialise anything that awaits: it is
/// re-entrant, so two runs both reading the keychain search list, then both
/// writing it back, interleave at the `await` and the second write erases the
/// first. Everything here that has to happen one run at a time — the search
/// list, signing, minting a certificate — spans several `security` or network
/// calls, so it needs a lock that is held *across* those awaits.
actor AsyncLock {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Whether a caller would have to wait right now. Advisory only — used to
    /// say so in the log, never to decide anything.
    var isHeld: Bool { held }

    func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        // Handed straight to the next waiter, so `held` never drops in between
        // and a newcomer cannot jump the queue.
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Run `body` holding the lock, releasing it on every exit path.
    nonisolated func run<T>(
        whileWaiting: (() -> Void)? = nil,
        _ body: () async throws -> T,
    ) async rethrows -> T {
        if let whileWaiting, await isHeld { whileWaiting() }
        await acquire()
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }
}

/// One `AsyncLock` per key, created on first use and kept for the process.
///
/// Keys are few — a team and a certificate type — so nothing is ever evicted.
actor KeyedLocks {
    private var locks: [String: AsyncLock] = [:]

    func lock(for key: String) -> AsyncLock {
        if let existing = locks[key] { return existing }
        let lock = AsyncLock()
        locks[key] = lock
        return lock
    }
}
