import DexCore
import DexUI
import AppKit
import SwiftUI

/// Whether the rows the column draws in AppKit come out as their SwiftUI views
/// would have. Run as `DexProbes --native-parity-probe <session>…`: every row of
/// those transcripts that has a native form is drawn both ways, at a wide and a
/// narrow pane, and any height that differs fails the run. Pixels are compared
/// too and the worst pairs written to `PARITY_DIR` for looking at.
@MainActor
enum NativeParityProbe {

    static let scheme: ColorScheme = ProcessInfo.processInfo.environment["PARITY_LIGHT"] != nil ? .light : .dark

    struct Reading {
        var rows = 0
        var heightsOff: [(String, CGFloat, CGFloat)] = []
        var pixels: [(String, Double)] = []
    }

    static func run() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let ids = Array(CommandLine.arguments.drop { $0 != "--native-parity-probe" }.dropFirst())
        let dir = ProcessInfo.processInfo.environment["PARITY_DIR"]
        if ProcessInfo.processInfo.environment["CALIBRATE"] != nil { calibrate(); return 0 }
        var items: [TranscriptItem] = []
        for id in ids { items += load(id) }

        // Some folds open, so the open forms are drawn as well as the shut.
        for (index, item) in items.enumerated() where index % 3 == 0 {
            if case .thinking(let prose) = item { RowExpansions.shared.toggle("think:\(prose.id)") }
        }

        var failed = false
        for width in [900.0, 520.0] {
            var reading = Reading()
            for item in items {
                guard let native = NativeRow.of(item, isLive: false) else { continue }
                reading.rows += 1
                let swiftUI = render(swiftUI: item, width: width)
                let appKit = render(native: native, width: width)
                if abs(swiftUI.height - appKit.height) > 0.01 {
                    reading.heightsOff.append((item.id, swiftUI.height, appKit.height))
                }
                let difference = differ(swiftUI.bitmap, appKit.bitmap)
                reading.pixels.append((item.id, difference))
                if let dir, difference > 0.002 || abs(swiftUI.height - appKit.height) > 0.01 {
                    let name = item.id.replacingOccurrences(of: ":", with: "-").prefix(40)
                    write(swiftUI.bitmap, to: "\(dir)/\(Int(width))-\(name)-swiftui.png")
                    write(appKit.bitmap, to: "\(dir)/\(Int(width))-\(name)-appkit.png")
                }
            }
            let worst = reading.pixels.sorted { $0.1 > $1.1 }.prefix(8)
            print("width \(Int(width)): \(reading.rows) native rows, \(reading.heightsOff.count) heights off")
            for (id, a, b) in reading.heightsOff.prefix(12) { print("  height \(id.prefix(40)): swiftui \(a), appkit \(b)") }
            for (id, difference) in worst { print(String(format: "  pixels %@: %.4f", String(id.prefix(40)), difference)) }
            failed = failed || !reading.heightsOff.isEmpty
        }
        return failed ? 1 : 0
    }

    private static func calibrate() {
        let samples = ["sed -n 190,275p Sources/App/Editor.swift", "Bash", "12 tool calls", "Read · Edit · Bash", "Thought", "summarized"]
        let faces: [(String, Font, NSFont)] = [
            ("mono", ChromeType.Reading.mono, NativeMetrics.mono),
            ("meta", ChromeType.Reading.meta, NativeMetrics.meta),
            ("metaMedium", ChromeType.Reading.meta.weight(.medium), NativeMetrics.metaMedium),
            ("metaItalic", ChromeType.Reading.meta.italic(), NativeMetrics.metaItalic),
        ]
        for (name, font, nsFont) in faces {
            for sample in samples {
                let size = NSHostingController(rootView: Text(sample).font(font).fixedSize()).sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
                let appKit = (sample as NSString).size(withAttributes: [.font: nsFont])
                print(String(format: "%@ %@: swiftui %.2f x %.2f, appkit %.2f x %.2f", name, sample, size.width, size.height, appKit.width, appKit.height))
            }
        }
        for symbol in ["chevron.right", "terminal", "doc.text"] {
            let size = NSHostingController(rootView: Image(systemName: symbol).font(ChromeType.Reading.icon).fixedSize()).sizeThatFits(in: CGSize(width: 100, height: 100))
            let image = NativeGlyph.image(symbol, color: .labelColor)
            print(String(format: "%@: swiftui %.2f x %.2f, appkit %.2f x %.2f", symbol, size.width, size.height, image?.size.width ?? 0, image?.size.height ?? 0))
        }
        let header = NSHostingController(rootView: HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "chevron.right").font(ChromeType.Reading.icon)
            Text("12 tool calls").font(ChromeType.Reading.meta.weight(.medium))
        }.fixedSize()).sizeThatFits(in: CGSize(width: 1000, height: 100))
        print("run header: \(header)")
        let thought = NSHostingController(rootView: HStack(spacing: 5) {
            Image(systemName: "chevron.right").font(ChromeType.Reading.icon)
            Text("Thought").font(ChromeType.Reading.meta.italic())
        }.fixedSize()).sizeThatFits(in: CGSize(width: 1000, height: 100))
        print("thought header: \(thought)")
        for glyph in ["chevron.right", "terminal", "doc.text", "wrench.and.screwdriver", "pencil", "magnifyingglass", "globe", "person.2", "square.and.pencil", "checklist", "wand.and.stars", "list.bullet.clipboard", "questionmark.bubble"] {
            let swift = NSHostingController(rootView: HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: glyph).font(ChromeType.Reading.icon).frame(width: 14, alignment: .leading)
                Text("Bash").font(ChromeType.Reading.meta.weight(.medium))
                Text("x").font(ChromeType.Reading.mono)
            }.fixedSize()).sizeThatFits(in: CGSize(width: 1000, height: 100))
            let image = NativeGlyph.image(glyph, color: .labelColor)!
            let attachment = NSTextAttachment()
            attachment.image = image
            let line = NSMutableAttributedString(attachment: attachment)
            line.append(NSAttributedString(string: " Bash", attributes: [.font: NativeMetrics.metaMedium]))
            let storage = NSTextStorage(attributedString: line)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 1000, height: 100))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let bounds = attachment.bounds
            print(String(format: "%@: swiftui %.1f; textkit %.2f; image %.1fx%.1f alignment %@", glyph, swift.height, used.height, image.size.width, image.size.height, NSStringFromRect(image.alignmentRect)) + " attach \(bounds)")
        }
        for font in [NativeMetrics.mono, NativeMetrics.meta, NativeMetrics.metaMedium] {
            print("\(font.fontName): ascender \(font.ascender) descender \(font.descender) leading \(font.leading) capHeight \(font.capHeight)")
        }
    }

    private static func load(_ id: String) -> [TranscriptItem] {
        let feed = TranscriptFeed()
        let task = Task { await feed.run(sessionID: id) }
        let began = ContinuousClock.now
        while feed.items.isEmpty, ContinuousClock.now - began < .seconds(30) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        task.cancel()
        return feed.items
    }

    private static func window(_ view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return window
    }

    private static func render(swiftUI item: TranscriptItem, width: CGFloat) -> (height: CGFloat, bitmap: NSBitmapImageRep) {
        let view = TranscriptItemView(item: item)
            .frame(maxWidth: ChromeMetrics.readingMeasure, alignment: .leading)
            .padding(.horizontal, ChromeMetrics.readingInset)
            .frame(maxWidth: .infinity, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(ChromeMetrics.readingLead)
            .environment(\.colorScheme, scheme)
        let measurer = NSHostingController(rootView: view)
        let height = measurer.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let host = NSHostingView(rootView: view.frame(maxHeight: .infinity, alignment: .top))
        let window = window(host, size: NSSize(width: width, height: max(1, height)))
        defer { window.contentView = nil }
        return (height, bitmap(host))
    }

    private static func render(native row: NativeRow, width: CGFloat) -> (height: CGFloat, bitmap: NSBitmapImageRep) {
        let text = min(ChromeMetrics.readingMeasure, width - 2 * ChromeMetrics.readingInset)
        let height = row.height(width: text, metrics: NativeMetrics.current)
        let cell = NativeCell(frame: .zero)
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        cell.show(row, lead: 0, place: 0, environment: environment) { _ in }
        let window = window(cell, size: NSSize(width: width, height: max(1, height)))
        defer { window.contentView = nil }
        return (height, bitmap(cell))
    }

    private static func bitmap(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The share of pixels that differ by more than antialiasing would, over
    /// the area both cover.
    private static func differ(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        let width = min(a.pixelsWide, b.pixelsWide)
        let height = min(a.pixelsHigh, b.pixelsHigh)
        guard width > 0, height > 0, let p = a.bitmapData, let q = b.bitmapData,
              a.bitsPerPixel == 32, b.bitsPerPixel == 32 else { return 1 }
        var differing = 0
        for y in 0..<height {
            let rowA = p + y * a.bytesPerRow
            let rowB = q + y * b.bytesPerRow
            for x in 0..<width {
                var delta: Int32 = 0
                for channel in 0..<4 {
                    delta = max(delta, abs(Int32(rowA[x * 4 + channel]) - Int32(rowB[x * 4 + channel])))
                }
                if delta > 64 { differing += 1 }
            }
        }
        return Double(differing) / Double(width * height)
    }

    private static func write(_ rep: NSBitmapImageRep, to path: String) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
