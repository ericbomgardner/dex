import DexCore
import DexUI
import AppKit
import SwiftUI

/// How long the real pane takes to switch between two real transcripts.
/// Run as `DexProbes --switch-probe <session> <session> [rounds]`.
@MainActor
enum SwitchProbe {

    @MainActor
    @Observable
    final class Stage {
        var attachment: PaneAttachment
        let feed = TranscriptFeed()
        init(_ attachment: PaneAttachment) { self.attachment = attachment }
    }

    @MainActor
    @Observable
    final class Shown {
        var current = 0
        let feeds = [TranscriptFeed(), TranscriptFeed()]
    }

    struct Kept: View {
        let shown: Shown
        let attachments: [PaneAttachment]
        let source: any TranscriptSource

        var body: some View {
            ZStack {
                ForEach(0..<2, id: \.self) { index in
                    TranscriptPane(
                        attachment: attachments[index],
                        feed: shown.feeds[index],
                        isWorking: false,
                        isLive: false,
                        source: source
                    )
                    .opacity(shown.current == index ? 1 : 0)
                    .allowsHitTesting(shown.current == index)
                }
            }
        }
    }

    struct Pane: View {
        let stage: Stage
        let source: any TranscriptSource

        var body: some View {
            TranscriptPane(
                attachment: stage.attachment,
                feed: stage.feed,
                isWorking: false,
                isLive: false,
                source: source
            )
        }
    }

    static func kept(_ attachments: [PaneAttachment], rounds: Int, dwell: Double) -> Int32 {
        let shown = Shown()
        let window = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: 900, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: Kept(shown: shown, attachments: attachments, source: LocalTranscriptSource()))
        window.makeKeyAndOrderFront(nil)
        let began = ContinuousClock.now
        while shown.feeds.contains(where: { $0.items.isEmpty }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        print("both open in \(Timing.ms(ContinuousClock.now - began))")
        for round in 0..<rounds {
            for index in [1, 0] {
                RunLoop.main.run(until: Date().addingTimeInterval(dwell))
                let began = ContinuousClock.now
                shown.current = index
                RunLoop.main.run(until: Date())
                window.contentView?.layoutSubtreeIfNeeded()
                window.contentView?.displayIfNeeded()
                print("round \(round) → \(index): \(Timing.ms(ContinuousClock.now - began))")
            }
        }
        for width in [880.0, 860, 900] {
            let began = ContinuousClock.now
            window.setContentSize(NSSize(width: width, height: 900))
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            print("resize to \(Int(width)): \(Timing.ms(ContinuousClock.now - began))")
        }
        window.orderOut(nil)
        window.contentView = nil
        return 0
    }

    static func run() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        guard let at = args.firstIndex(of: "--switch-probe"), args.count > at + 2 else {
            FileHandle.standardError.write(Data("usage: --switch-probe <session> <session> [rounds]\n".utf8))
            return 2
        }
        let ids = [args[at + 1], args[at + 2]]
        let rounds = args.count > at + 3 ? Int(args[at + 3]) ?? 3 : 3
        let dwell = Double(ProcessInfo.processInfo.environment["SWITCH_DWELL"] ?? "0") ?? 0
        let attachments = ids.map { PaneAttachment(hostKey: $0, workingDirectory: nil, sessionID: $0) }

        if ProcessInfo.processInfo.environment["SWITCH_KEEP"] != nil {
            return kept(attachments, rounds: rounds, dwell: dwell)
        }
        let stage = Stage(attachments[0])
        let window = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: 900, height: 900),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: Pane(stage: stage, source: LocalTranscriptSource()))
        window.makeKeyAndOrderFront(nil)

        func shown(_ id: String) -> Bool {
            stage.feed.heardOf == id && !stage.feed.items.isEmpty
        }

        func settle(on id: String) -> (Duration, Duration) {
            let began = ContinuousClock.now
            var drawn: Duration = .zero
            while !shown(id) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                if ContinuousClock.now - began > .seconds(30) { break }
            }
            let landed = ContinuousClock.now - began
            let drawing = ContinuousClock.now
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            RunLoop.main.run(until: Date())
            drawn = ContinuousClock.now - drawing
            return (landed, drawn)
        }

        let (firstLanded, firstDrawn) = settle(on: ids[0])
        print("open \(ids[0].prefix(8)): items in \(Timing.ms(firstLanded)), drawn in \(Timing.ms(firstDrawn)); \(stage.feed.items.count) items")

        for round in 0..<rounds {
            for (index, attachment) in [attachments[1], attachments[0]].enumerated() {
                RunLoop.main.run(until: Date().addingTimeInterval(dwell))
                let began = ContinuousClock.now
                stage.attachment = attachment
                let (landed, drawn) = settle(on: attachment.sessionID!)
                let total = ContinuousClock.now - began
                print("round \(round) → \(attachment.hostKey.prefix(8)) [\(round == 0 && index == 0 ? "cold" : "kept")]: items in \(Timing.ms(landed)), drawn in \(Timing.ms(drawn)), total \(Timing.ms(total)); \(stage.feed.items.count) items")
                if let dir = ProcessInfo.processInfo.environment["SNAP"], let view = window.contentView {
                    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/pane-\(round)-\(attachment.hostKey.prefix(8)).png"))
                }
            }
        }

        window.orderOut(nil)
        window.contentView = nil
        return 0
    }
}
