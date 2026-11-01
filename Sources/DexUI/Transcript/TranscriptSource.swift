import DexCore
import Foundation

/// What a session has written, wherever it wrote it. The feeds ask through
/// this rather than reading the disk themselves.
package protocol TranscriptSource: AnyObject, Sendable {

    /// Where this session's transcript is, once it has one. Nil until it is
    /// written — the CLI names the file before it exists.
    func locate(sessionID: String) async -> String?

    /// The whole records written since `offset`, and where the next read starts.
    func read(_ path: String, from offset: Int) async -> TranscriptRead

    /// Where this session's agents write, given the transcript actually opened.
    /// Derived from the path rather than from the session id: a session that
    /// changes directory takes the whole folder with it.
    func subagentDirectory(besideParent path: String) -> String?

    func locateAgent(_ agentID: String, in directory: String) async -> String?

    /// Which model and effort an agent ran on, off the head of its own file.
    func identity(agentID: String, in directory: String) async -> SubagentIdentity?

    /// What an agent is carrying, off the tail of its own file.
    func context(agentID: String, in directory: String) async -> SessionContext?

    /// Wakes the caller when that path is written to. Nil where nothing is
    /// watching and the interval below is the whole of the wait.
    func changes(to path: String) -> AsyncStream<Void>?

    /// The backstop between passes. Short where a read is a file handle, long
    /// where it is a round trip and a watch is doing the waking.
    var interval: Duration { get }
}

/// One pass over a transcript: what was whole, and what the file did under it.
package struct TranscriptRead: Sendable {
    var lines: [Data] = []
    /// Where the next read starts. Unmoved where nothing whole arrived.
    var offset: Int
    /// The file is shorter than where we were reading, so it is not the file we
    /// were reading. Whatever was parsed from it is stale.
    var restarted = false
    /// The file is no longer there. A session that changes directory takes its
    /// transcript with it, and looking again finds where it went.
    var vanished = false
    /// How long the read itself took, as opposed to how long the caller waited
    /// for it — the difference is time spent queued behind other disk work.
    var took: Duration = .zero
}

// MARK: - The disk

/// The disk: the tail, the locator and the existence check, the same three
/// calls the feeds once made inline.
package final class LocalTranscriptSource: TranscriptSource {
    private let locator: TranscriptLocator

    package init(locator: TranscriptLocator = TranscriptLocator()) {
        self.locator = locator
    }

    /// Long enough not to spin, short enough that a reply lands about when the
    /// terminal would have shown it.
    package let interval = Duration.milliseconds(600)

    // At the reader's priority: this is the read they are waiting on, and at
    // utility it queued behind every digest and identity read in the app.
    package func locate(sessionID: String) async -> String? {
        let locator = self.locator
        return await Task.detached(priority: .userInitiated) {
            locator.locate(sessionID: sessionID)?.path
        }.value
    }

    package func read(_ path: String, from offset: Int) async -> TranscriptRead {
        await Task.detached(priority: .userInitiated) {
            let began = ContinuousClock.now
            var tail = TranscriptTail(url: URL(fileURLWithPath: path), offset: UInt64(offset))
            let batch = tail.read()
            return TranscriptRead(
                lines: batch.lines,
                offset: Int(tail.offset),
                restarted: batch.restarted,
                vanished: !FileManager.default.fileExists(atPath: path),
                took: ContinuousClock.now - began
            )
        }.value
    }

    package func subagentDirectory(besideParent path: String) -> String? {
        SubagentTranscript.directory(besideParent: URL(fileURLWithPath: path))?.path
    }

    package func locateAgent(_ agentID: String, in directory: String) async -> String? {
        await Task.detached(priority: .utility) {
            SubagentTranscript.locate(
                agentID: agentID, in: URL(fileURLWithPath: directory, isDirectory: true)
            )?.path
        }.value
    }

    package func identity(agentID: String, in directory: String) async -> SubagentIdentity? {
        await Task.detached(priority: .utility) {
            SubagentTranscript.identity(
                agentID: agentID, in: URL(fileURLWithPath: directory, isDirectory: true)
            )
        }.value
    }

    package func context(agentID: String, in directory: String) async -> SessionContext? {
        await Task.detached(priority: .utility) {
            SubagentTranscript.context(
                agentID: agentID, in: URL(fileURLWithPath: directory, isDirectory: true)
            )
        }.value
    }

    /// A write wakes the feed at once; the poll behind it is the backstop.
    /// Without this, everything the CLI writes waited up to the whole interval
    /// to be drawn — the prompt after a send, the queue it went into, the
    /// reply — each hop paying its own share.
    package func changes(to path: String) -> AsyncStream<Void>? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue(label: "transcript-changes", qos: .utility)
        )
        return AsyncStream { continuation in
            source.setEventHandler {
                // A rename is a session that changed directory: one last wake
                // lets the feed find the file gone and look again.
                continuation.yield(())
                if !source.data.isDisjoint(with: [.delete, .rename]) { continuation.finish() }
            }
            source.setCancelHandler { close(descriptor) }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }
}

// MARK: - Waiting

/// Sleeps until the file moved or the backstop ran out, whichever comes first.
///
/// Where a source watches nothing this is exactly the sleep it replaces.
@MainActor
final class TranscriptWake {
    private var pending = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var pump: Task<Void, Never>?

    /// Kept across the wait rather than opened per pass: a watch registered and
    /// dropped every few seconds is a request each way for nothing.
    func follow(_ changes: AsyncStream<Void>?) {
        guard let changes else { return }
        pump?.cancel()
        pump = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                self.signal()
            }
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil
        signal()
    }

    /// A change that lands between two waits is remembered rather than lost —
    /// otherwise a write answered while the last pass was still reading would
    /// wait out the whole backstop.
    private func signal() {
        guard let held = waiting else { return pending = true }
        waiting = nil
        held.resume()
    }

    func wait(upTo interval: Duration) async {
        if pending {
            pending = false
            return
        }
        let backstop = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.signal()
        }
        await withCheckedContinuation { continuation in
            // Only one waiter, and the feed is it: a second would drop the
            // first's continuation and suspend it for good.
            waiting?.resume()
            waiting = continuation
        }
        backstop.cancel()
    }
}
