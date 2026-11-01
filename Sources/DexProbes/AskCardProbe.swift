import DexCore
import DexUI
import AppKit
import SwiftUI

/// What the ask card does when it is driven rather than described. Run as
/// `DexProbes --ask-card-probe`; anything it finds wrong fails the run.
///
/// Four readings, each of something a test can't reach. Two are heights that are
/// arithmetic — `AskCardHeight`'s share of the column, and the permission card's
/// cap on the command it is asking about — but that arrive through a
/// measurement, and only a hosted card says the measurement still reaches them.
/// The other two are hit testing and key
/// handling, which are answers the frameworks give and not ones we write:
/// SwiftUI hands a click to a view's *content*, so a row that is a word inside
/// an empty frame is clickable on the word alone; and its own field will not
/// take a typed newline on macOS at all, which is why the card's is AppKit.
@MainActor
enum AskCardProbe {

    private static func ask(options: Int, detail: Int, previews: Bool) -> HostAsk {
        let choices = (0..<options).map { index -> JSONValue in
            var option: [String: JSONValue] = [
                "label": .string("Option \(index + 1)"),
                "description": .string(String(repeating: "a reason to pick it, ", count: detail)),
            ]
            if previews {
                option["preview"] = .string("<div style=\"padding:12px\">Option \(index + 1)</div>")
            }
            return .object(option)
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
                        // Chosen so a stray pick can't turn the page under the
                        // sweep below.
                        "multiSelect": .bool(true),
                        "options": .array(choices),
                    ])
                ])
            ]),
            options: []
        )
    }

    private static func permission(lines: Int) -> HostAsk {
        let command = (0..<lines).map { "print(\"line \($0)\")" }.joined(separator: "\n")
        return HostAsk(
            askId: "probe",
            key: "probe",
            kind: .permission,
            toolName: "Bash",
            input: .object(["command": .string("python3 - <<'EOF'\n" + command)]),
            options: [
                HostAskOption(optionId: "allow_once", name: "Allow", kind: .allowOnce),
                HostAskOption(optionId: "reject_once", name: "Deny", kind: .rejectOnce),
            ]
        )
    }

    /// The card with somewhere to write, which is how the app draws it: the
    /// answers are the store's, not the card's, so a card handed a constant
    /// binding puts every keystroke straight back where it found it.
    private struct Staged: View {
        let ask: HostAsk
        let columnHeight: CGFloat

        @State private var reading: String?
        @State private var drafts = AskDrafts()

        var body: some View {
            AskCard(
                asks: [ask],
                columnHeight: columnHeight,
                onAnswerQuestion: { _, _, _ in },
                onAnswerPermission: { _, _ in },
                reading: $reading,
                drafts: $drafts
            )
        }
    }

    private static func card(_ ask: HostAsk, columnHeight: CGFloat) -> Staged {
        Staged(ask: ask, columnHeight: columnHeight)
    }

    static func run() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)

        var report: [String: Any] = [:]
        var failed = false

        let (heights, heightsHeld) = share()
        report["share"] = heights
        failed = failed || !heightsHeld

        let (commands, commandsHeld) = command()
        report["command"] = commands
        failed = failed || !commandsHeld

        let (clicked, clickHeld) = clickTarget()
        report["clickTarget"] = clicked
        failed = failed || !clickHeld

        let (typed, typeHeld) = newline()
        report["newline"] = typed
        failed = failed || !typeHeld

        let undo = undoStacks()
        report["undo"] = undo?.reported ?? ["error": "no field to type into"]
        failed = failed || !(undo?.held ?? false)

        report["passed"] = !failed
        let data = try? JSONSerialization.data(withJSONObject: report,
                                               options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data ?? Data())
        FileHandle.standardOutput.write(Data("\n".utf8))
        return failed ? 1 : 0
    }

    // MARK: - The cap

    private static func share() -> ([[String: Any]], Bool) {
        let shapes: [(String, HostAsk)] = [
            ("short", ask(options: 2, detail: 1, previews: false)),
            ("long", ask(options: 4, detail: 12, previews: false)),
            ("previews", ask(options: 4, detail: 4, previews: true)),
        ]

        var rows: [[String: Any]] = []
        var held = true

        for (name, ask) in shapes {
            let natural = height(of: ask, columnHeight: 0)
            for column in [CGFloat(500), 700, 900] {
                let measured = height(of: ask, columnHeight: column)
                // Its own height or its share of the column, whichever is less —
                // a point of slack, since both are measured.
                let within = measured <= min(natural, column * 0.6) + 1
                held = held && within
                rows.append([
                    "shape": name,
                    "column": column,
                    "natural": natural.rounded(),
                    "cardHeight": measured.rounded(),
                    "shareOfColumn": ((measured / column) * 100).rounded(),
                    "withinShare": within,
                ])
            }
        }
        return (rows, held)
    }

    // MARK: - The command

    /// The permission card shows the whole command, and the buttons that answer
    /// it sit under it. Both ends fail quietly: a panel that never hears its
    /// measurement is a point tall and shows nothing, and one that isn't bounded
    /// pushes the buttons off the card. So a short command has to grow the card
    /// and a long one has to stop growing it.
    private static func command() -> ([[String: Any]], Bool) {
        let counts = [1, 5, 400]
        var rows: [[String: Any]] = []
        var measured: [Int: CGFloat] = [:]

        for lines in counts {
            let card = height(of: permission(lines: lines), columnHeight: 0)
            measured[lines] = card
            rows.append(["lines": lines, "cardHeight": card.rounded()])
        }

        let grew = (measured[5] ?? 0) > (measured[1] ?? 0) + ChromeType.Reading.monoLine
        // The panel's own cap plus the card around it, which the one-line card
        // measures for us.
        let ceiling = (measured[1] ?? 0)
            + ChromeType.Reading.monoLine * CGFloat(ChromeMetrics.previewMaxLines)
        let bounded = (measured[400] ?? 0) <= ceiling

        rows.append(["grewWithTheCommand": grew, "boundedAt": ceiling.rounded(), "bounded": bounded])
        return (rows, grew && bounded)
    }

    private static func height(of ask: HostAsk, columnHeight: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: card(ask, columnHeight: columnHeight))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 4000)
        host.layoutSubtreeIfNeeded()
        // The height is measured and fed back, so it takes a runloop and a
        // second pass to arrive; read on the first, every card is a point tall.
        spin()
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    // MARK: - The click

    /// Clicked down the card's right-hand edge, where there is nothing but the
    /// rows' own width. The answer field opening means the "Something else…" row
    /// took a click on empty space rather than on its words.
    private static func clickTarget() -> ([String: Any], Bool) {
        let window = staged(ask(options: 2, detail: 2, previews: false))
        defer { window.orderOut(nil) }

        let width = window.contentView?.bounds.width ?? 0
        var openedAt: CGFloat?

        for step in stride(from: CGFloat(4), to: window.contentView?.bounds.height ?? 0, by: 6) {
            click(in: window, at: NSPoint(x: width - 20, y: step))
            if answerField(in: window) != nil {
                openedAt = step
                break
            }
        }

        return ([
            "opened": openedAt != nil,
            "atY": openedAt.map { $0.rounded() } ?? -1,
        ], openedAt != nil)
    }

    // MARK: - The newline

    /// Shift-return into the card's own field, which is the composer's editor
    /// and not SwiftUI's: return commits the answer, shift-return breaks the
    /// line.
    private static func newline() -> ([String: Any], Bool) {
        let window = staged(ask(options: 2, detail: 2, previews: false))
        defer { window.orderOut(nil) }

        let width = window.contentView?.bounds.width ?? 0
        for step in stride(from: CGFloat(4), to: window.contentView?.bounds.height ?? 0, by: 6) {
            click(in: window, at: NSPoint(x: width - 20, y: step))
            if answerField(in: window) != nil { break }
        }

        guard let editor = answerField(in: window) else {
            return (["error": "no field to type into"], false)
        }
        window.makeFirstResponder(editor)
        spin()

        let opened = editor.frame.height
        type("one", in: window)
        send(to: window, characters: "\r", shift: true, keyCode: 36)
        type("two", in: window)
        spin()

        let text = editor.string
        let broke = text.contains("\n")
        let grew = editor.frame.height > opened

        return ([
            "text": text.replacingOccurrences(of: "\n", with: "\\n"),
            "brokeTheLine": broke,
            "grew": grew,
            "openedHeight": opened.rounded(),
            "typedHeight": editor.frame.height.rounded(),
        ], broke && grew)
    }

    // MARK: - The undo stack

    /// Where the field's undo actions are registered, and what is left of them
    /// once the card goes.
    struct UndoReading {
        /// The editor keeps a stack of its own rather than the window's.
        let ownStack: Bool
        /// Cmd-Z in the field still takes the typing back.
        let fieldUndoes: Bool
        /// Anything left on the window's own stack once the card has gone —
        /// which is the crash: `NSUndoManager` does not retain what it
        /// registers against, so an action left here outlives the editor it
        /// names and the next Cmd-Z sends to freed memory.
        let windowHolds: Bool

        var held: Bool { ownStack && fieldUndoes && !windowHolds }

        var reported: [String: Any] {
            [
                "ownStack": ownStack,
                "fieldUndoes": fieldUndoes,
                "windowHolds": windowHolds,
                "passed": held,
            ]
        }
    }

    /// Types into the card's own field, throws the card away, and reads what is
    /// left behind. The pane builds a new card for every session it is pointed
    /// at, so this teardown is what an ordinary switch away does — and a Cmd-Z
    /// after one used to come back through `_NSUndoStack popAndInvoke` into an
    /// editor that had been freed.
    static func undoStacks() -> UndoReading? {
        let window = staged(ask(options: 2, detail: 2, previews: false))
        defer { window.orderOut(nil) }

        // Read before anything takes the responder, so this is the window's own
        // and not whatever the first responder is offering.
        let stack = window.undoManager

        let width = window.contentView?.bounds.width ?? 0
        for step in stride(from: CGFloat(4), to: window.contentView?.bounds.height ?? 0, by: 6) {
            click(in: window, at: NSPoint(x: width - 20, y: step))
            if answerField(in: window) != nil { break }
        }

        var reading: (own: Bool, undoes: Bool)?

        autoreleasepool {
            guard let editor = answerField(in: window) else { return }
            window.makeFirstResponder(editor)
            spin()

            type("one", in: window)
            spin()

            let typed = editor.string
            let own = editor.undoManager !== stack && editor.undoManager != nil
            editor.undoManager?.undo()
            spin()
            let undone = !typed.isEmpty && editor.string != typed

            // Typed again so there is something on the stack to be left
            // behind — the undo above pops the only action there was, and a
            // stack emptied by the reading reads as clean whoever it belongs to.
            type("two", in: window)
            spin()

            reading = (own, undone)
        }

        guard let reading else { return nil }

        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 700))
        window.makeFirstResponder(window)
        spin()

        return UndoReading(
            ownStack: reading.own,
            fieldUndoes: reading.undoes,
            windowHolds: stack?.canUndo ?? false
        )
    }

    // MARK: - Driving

    private static func staged(_ ask: HostAsk) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: 520, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // Off every screen and invisible with it: AppKit pulls a titled window
        // back onto a screen, and this one would land over whatever you were
        // reading.
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: card(ask, columnHeight: 700))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        spin()
        return window
    }

    private static func answerField(in window: NSWindow) -> ComposerTextView? {
        guard let root = window.contentView else { return nil }
        return editors(in: root).first { $0.placeholder == "Your answer" }
    }

    private static func editors(in view: NSView) -> [ComposerTextView] {
        var found: [ComposerTextView] = []
        if let editor = view as? ComposerTextView { found.append(editor) }
        for child in view.subviews { found += editors(in: child) }
        return found
    }

    private static func click(in window: NSWindow, at point: NSPoint) {
        for phase in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: phase,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: phase == .leftMouseDown ? 1 : 0
            ) else { continue }
            window.sendEvent(event)
        }
        spin(times: 2)
    }

    private static func type(_ text: String, in window: NSWindow) {
        for character in text {
            send(to: window, characters: String(character), shift: false, keyCode: 0)
        }
    }

    private static func send(to window: NSWindow, characters: String, shift: Bool, keyCode: UInt16) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shift ? .shift : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        window.sendEvent(event)
        spin(times: 2)
    }

    private static func spin(times: Int = 6) {
        for _ in 0..<times {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }
}
