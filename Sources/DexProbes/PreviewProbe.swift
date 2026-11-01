import DexCore
import DexUI
import AppKit
import SwiftUI
import WebKit

/// What a card full of option previews costs, measured rather than assumed.
///
/// Every option carries its own mockup and they are all on screen at once, so a
/// question is N web views rather than one. Run as `DexProbes --preview-probe`.
enum PreviewProbe {

    /// Sized from a real captured payload: seven options across two questions,
    /// each preview between roughly 550 and 1400 characters of markup.
    private static func fragment(_ index: Int, padding: Int) -> String {
        """
        <div style="padding:12px;border:1px solid #ddd;border-radius:8px">
          <div style="font-size:12px;color:#666">Option \(index)</div>
          <div style="font-size:28px;font-weight:600">1,\(200 + index)</div>
          <div style="font-size:11px;color:#999">\(String(repeating: "detail ", count: padding))</div>
        </div>
        """
    }

    private static func ask(options: Int) -> HostAsk {
        let choices = (0..<options).map { index in
            JSONValue.object([
                "label": .string("Option \(index + 1)"),
                "description": .string("What picking this one would mean, at about the length these run."),
                "preview": .string(fragment(index + 1, padding: 20 + index * 30)),
            ])
        }
        return HostAsk(
            askId: "probe",
            key: "probe",
            kind: .question,
            toolName: "AskUserQuestion",
            input: .object([
                "questions": .array([
                    .object([
                        "question": .string("How should the status card be laid out?"),
                        "header": .string("Layout"),
                        "multiSelect": .bool(false),
                        "options": .array(choices),
                    ])
                ])
            ]),
            options: []
        )
    }

    static func run() -> Int32 {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        var rows: [[String: Any]] = []

        for count in [1, 2, 4, 7] {
            let card = AskCard(
                asks: [ask(options: count)],
                // Unbounded, since what is being measured is what N previews
                // cost to draw, not how many of them fit a pane.
                columnHeight: 0,
                onAnswerQuestion: { _, _, _ in },
                onAnswerPermission: { _, _ in },
                reading: .constant(nil),
                drafts: .constant(AskDrafts())
            )

            let started = CFAbsoluteTimeGetCurrent()
            let host = NSHostingView(rootView: card)
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 2000)
            host.layoutSubtreeIfNeeded()
            let laidOut = CFAbsoluteTimeGetCurrent() - started

            // Web views load on the main runloop, so the cost of the content is
            // only visible after spinning it; a card that lays out fast and then
            // stutters for a second is still a card that stutters.
            let settled = spin(until: { loaded(in: host) >= count }, limit: 10)
            let total = CFAbsoluteTimeGetCurrent() - started

            rows.append([
                "options": count,
                "layoutMs": (laidOut * 1000).rounded(),
                "settledMs": (total * 1000).rounded(),
                "webViews": webViews(in: host).count,
                "allLoaded": settled,
                "footprintMB": (Double(footprint()) / 1_048_576).rounded(),
            ])
        }

        let report: [String: Any] = [
            "probedAt": ISO8601DateFormatter().string(from: Date()),
            "previewMaxHeight": AskPreview.maxHeight,
            "rows": rows,
        ]
        let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data ?? Data())
        FileHandle.standardOutput.write(Data("\n".utf8))
        return 0
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        var found: [WKWebView] = []
        if let web = view as? WKWebView { found.append(web) }
        for child in view.subviews { found += webViews(in: child) }
        return found
    }

    private static func loaded(in view: NSView) -> Int {
        webViews(in: view).filter { !$0.isLoading && $0.estimatedProgress >= 1 }.count
    }

    private static func spin(until done: () -> Bool, limit: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while !done(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return done()
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
