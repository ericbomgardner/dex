import DexCore
import DexUI
import AppKit
import SwiftUI

/// The real pane following a transcript as it is written. Run as
/// `DexProbes --live-probe <session>`: the first part of that transcript is
/// copied to a file of the probe's own, the pane opened on it, and the rest
/// written in a few at a time. At the end, it has to stay at the end through
/// every write; scrolled back, nothing written may move the reader.
@MainActor
enum LiveProbe {

    /// The disk for everything, except that the session is found where the
    /// probe put it rather than among the real transcripts.
    final class Source: TranscriptSource {
        let path: String
        private let disk = LocalTranscriptSource()
        init(path: String) { self.path = path }
        func locate(sessionID: String) async -> String? { path }
        func read(_ path: String, from offset: Int) async -> TranscriptRead { await disk.read(path, from: offset) }
        func subagentDirectory(besideParent path: String) -> String? { nil }
        func locateAgent(_ agentID: String, in directory: String) async -> String? { nil }
        func identity(agentID: String, in directory: String) async -> SubagentIdentity? { nil }
        func context(agentID: String, in directory: String) async -> SessionContext? { nil }
        func changes(to path: String) -> AsyncStream<Void>? { disk.changes(to: path) }
        var interval: Duration { disk.interval }
    }

    static func run() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard let id = CommandLine.arguments.drop(while: { $0 != "--live-probe" }).dropFirst().first,
              let original = TranscriptLocator().locate(sessionID: id),
              let text = try? String(contentsOf: original, encoding: .utf8) else { return 2 }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-probe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("\(id).jsonl")
        let start = lines.count * 2 / 3
        try? (lines[..<start].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let feed = TranscriptFeed()
        let window = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: 900, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: TranscriptPane(
            attachment: PaneAttachment(hostKey: id, workingDirectory: nil, sessionID: id),
            feed: feed, isWorking: false, isLive: true, source: Source(path: file.path)
        ))
        window.makeKeyAndOrderFront(nil)
        let began = ContinuousClock.now
        while feed.items.isEmpty, ContinuousClock.now - began < .seconds(30) { spin(1) }
        spin(30)
        let columns: [ColumnView] = found(in: window.contentView!)
        guard let column = columns.first else { return 2 }
        let clip = column.scrollView.contentView

        func shortBy() -> CGFloat {
            (column.scrollView.documentView?.frame.height ?? 0) - clip.bounds.maxY
        }
        func append(_ count: Int, from at: inout Int) -> Int {
            let end = min(lines.count, at + count)
            guard end > at, let handle = try? FileHandle(forWritingTo: file) else { return 0 }
            handle.seekToEndOfFile()
            handle.write(Data((lines[at..<end].joined(separator: "\n") + "\n").utf8))
            try? handle.close()
            let wrote = end - at
            at = end
            return wrote
        }

        var at = start
        var failed = false
        var steps = 0
        let half = (lines.count - start) / 2
        // At the end: every write lands at the end.
        while at < start + half {
            let before = feed.items.count
            // A click at the bottom of the pane first, beside the last line
            // where it opens nothing, as a reader at the end does to put the
            // caret there: following has to survive it.
            let bottom = clip.convert(NSPoint(x: clip.bounds.minX + 10, y: clip.bounds.maxY - 30), to: nil)
            for phase in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: phase, location: bottom, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: phase == .leftMouseUp ? 0 : 1
                ) { NSApp.sendEvent(event) }
            }
            spin(2)
            guard append(8, from: &at) > 0 else { break }
            spin(50)
            steps += 1
            let short = shortBy()
            if abs(short) > TranscriptColumn.slack {
                print("FAIL at the end, write \(steps): \(short) short, items \(before) → \(feed.items.count)")
                failed = true
            }
        }
        print("at the end: \(steps) writes, items now \(feed.items.count), short \(shortBy())")

        // Scrolled back: no write moves the reader.
        clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.minY - 600)))
        column.scrollView.reflectScrolledClipView(clip)
        spin(10)
        let place = clip.bounds.minY
        steps = 0
        while at < lines.count {
            guard append(8, from: &at) > 0 else { break }
            spin(50)
            steps += 1
            if abs(clip.bounds.minY - place) > 0.5 {
                print("FAIL scrolled back, write \(steps): moved \(clip.bounds.minY - place)")
                failed = true
            }
        }
        print("scrolled back: \(steps) writes, items now \(feed.items.count), moved \(clip.bounds.minY - place)")
        window.orderOut(nil)
        return failed ? 1 : 0
    }

    private static func found<Kind: NSView>(in view: NSView) -> [Kind] {
        var kind: [Kind] = []
        if let match = view as? Kind { kind.append(match) }
        for child in view.subviews { kind += found(in: child) }
        return kind
    }

    private static func spin(_ times: Int) {
        for _ in 0..<times { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
}
