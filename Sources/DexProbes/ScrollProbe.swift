import DexCore
import DexUI
import AppKit
import SwiftUI

/// What a pane that changes height does to the reader's place in the
/// transcript. Run as `DexProbes --scroll-probe`; anything it finds wrong
/// fails the run, and `TranscriptScrollTests` drives the same readings on every
/// `swift test`, which is the trigger this one has that the others don't.
///
/// The reading no unit test can reach on its own: what the real column does
/// when the *viewport* shrinks is not what it does when the content grows, and
/// both come through AppKit's scroll view. Every case is staged on the real
/// `TranscriptColumn`, and on a control — a plain SwiftUI scroll view anchored
/// to the bottom, which is what the pane was before any of this — so the
/// numbers say what the column carries rather than only that it holds.
@MainActor
enum ScrollProbe {

    /// How the column was put together for a reading. Only `scroller` is real
    /// code; the other is the control.
    enum Arrangement: String, CaseIterable {
        /// `TranscriptColumn` as the pane draws it.
        case scroller
        /// What the pane had before: a SwiftUI scroll view with the bottom
        /// anchor and nothing else.
        case anchorAlone
    }

    /// What a case does to the pane, and what that did to the transcript.
    enum Case: String, CaseIterable {
        /// Nothing moves. The reading is that the pane opens at the bottom, and
        /// that at rest SwiftUI's own arithmetic agrees with AppKit's about
        /// where that is — the gate reads SwiftUI's number, and on the frame a
        /// change lands it is the one number that answers for something else.
        case opens
        /// The strip appears and takes its points out of the viewport.
        case stripAppears
        /// The real submit: the strip appears and "Thinking…" is appended in the
        /// same update. Content growing does not absorb the container shrinking
        /// — they are separate sums, and believing otherwise costs a line.
        case stripAppearsWithThinking
        /// A whole submit as the app performs it, in the order and the
        /// separate updates it really arrives in: the field empties and gives
        /// its lines back, the strip and "Thinking…" land when the session
        /// picks the turn up, and the prompt itself lands last, when the
        /// transcript on disk catches up.
        case submits
        /// The same submit made from up the conversation, which is the one the
        /// geometry can't answer: the pane is somewhere back in the transcript —
        /// carried there by a window drag, or left there by a reader who came
        /// back to the box to type — and hitting return has to bring the end
        /// down and hold it there for the turn that follows.
        case submitsFromUpTheConversation
        /// The shortfall a window drag leaves, cleared the way it is cleared in
        /// practice: by saying something. The drag is unattributable and stays
        /// unanswered — see `aTurnAfterAWindowDrag` — so the pane is left short
        /// and carries it, and a reader who goes back to the box and types is
        /// the next thing that says where they are.
        case sendsAfterAWindowDrag
        /// And what that hold costs, which is nothing: having sent a message,
        /// the reader goes back up the conversation while the session is
        /// writing into it. Nothing written under them may take the page away
        /// again — not the turn landing as they go, and not the ones after it.
        case scrolledBackAfterASend
        /// An agent is sent mid-turn and takes a row in the strip, which the
        /// transcript pays for out of the same viewport — the strip arriving is
        /// not the last time it changes height. Staged with the session writing
        /// as it happens, which is what a turn that delegates is doing.
        case anotherAgentJoins
        /// The same, with nothing said from the composer: what an agent joining
        /// costs a reader who is watching a session they never sent to, and the
        /// only thing the shrink answer has to go on.
        case anotherAgentJoinsUnasked
        /// The turn ends and the viewport the strip was taking room from is the
        /// transcript's again.
        case stripLeaves
        /// The one that always worked, and the reason the anchor stays: a turn
        /// lands and the pane follows it down.
        case turnLands
        /// The same shrink as the strip with no submit anywhere near it — five
        /// typed lines, and the last thing said slides under the fold.
        case composerGrows
        /// Reading back through the conversation. Nothing may move the place the
        /// reader is holding, neither the strip arriving nor a turn under it.
        case scrolledBack
        /// Scrolled back, and then left there through a whole turn of the
        /// session — strip up, a turn landing, strip down, strip up again. One
        /// container change is not the reading: a gate that re-arms on
        /// something the *layout* did rather than on something the reader did
        /// holds for the first of those and yanks the page out from under them
        /// on the second.
        case scrolledBackThroughATurn
        /// Scrolled back and then returned to the end by hand. The gate has to
        /// re-arm, or the fix works once per pane and never again.
        case returnsToBottom
        /// The container change that arrives from outside rather than from
        /// anything the session did: the window dragged shorter. A reader at the
        /// end stays at the end — the column knows they were there, rather than
        /// inferring it from a burst of readings, which is what left the
        /// SwiftUI pane the full height short.
        case windowShrinks
        /// And what a session goes on doing after one — dragged, then a strip, a
        /// turn, a strip going and one arriving again, which is a whole turn on
        /// a pane that has just been resized. At the end after every one of
        /// them. The SwiftUI pane carried the drag's shortfall into each change
        /// after it (120, 146, 258, 232, 258 short), and `anchorAlone` still does.
        case aTurnAfterAWindowDrag
        /// Read back up one session, over to another, and back: the first is
        /// where it was left. The other's content swaps in under the same
        /// column, which is what a switch to a session the feed has kept does.
        case returnsToItsPlace
        /// The same, with the column gone in between, which is what a switch
        /// to a session the feed has to read again does.
        case returnsToItsPlaceAfterARead
        /// Read back up one session and over to another never opened here: the
        /// other opens at its end, not at the place carried from the first.
        case opensAnotherAtItsEnd
        /// Left at the end, a turn lands while away, and coming back is to the
        /// new end rather than to the offset the old one was at.
        case returnsToTheEndItGrew
        /// A row above the place was open when it was left and comes back shut,
        /// as an expanded tool row does: the place is the same line, not the
        /// same offset.
        case returnsToItsPlaceAfterARowAboveShrank
        /// The transcript comes back in two passes, the first shorter than the
        /// place: the place waits for the rest rather than being lost.
        case returnsToItsPlaceReadInPasses
        /// Left at the very top, above the first row's padding.
        case returnsToTheTop
        /// The row the place was kept against is gone on return, as a run split
        /// around a call that has since settled is: the offset stands in, and a
        /// send afterwards still holds the end.
        case returnsWhenItsRowIsGone
        /// Read back to the top, and the way back pressed: it shows only once
        /// the reader is well up, and holds the end through the turn after it
        /// the way a send does.
        case jumpsToTheEnd
        /// Opened in a pane that runs up under the titlebar, as the window's
        /// does. AppKit insets the scroll view for it once it is in the window,
        /// after the column has already put the reader at the end.
        case opensUnderTheTitlebar
    }

    /// What one case did to the scroll view.
    struct Reading {
        /// How far off the bottom the transcript was left. This is the defect,
        /// in points.
        let shortBy: CGFloat
        /// How far the reader's place moved. The reading for a reader who was
        /// not at the bottom, where staying put is the whole requirement.
        let drift: CGFloat
        let viewportBefore: CGFloat
        let viewportAfter: CGFloat
        /// The gap SwiftUI reported below the viewport — the number the
        /// mechanism gates on, kept so it can be held against `shortBy`.
        let gap: CGFloat
        /// What the pane was short by after each step of a case that takes more
        /// than one. The last of these is `shortBy`.
        let trail: [Step]
        var held = false

        func shortBy(after step: String) -> CGFloat? {
            trail.first { $0.name == step }?.shortBy
        }
    }

    /// What one step of a case left behind.
    struct Step {
        let name: String
        let shortBy: CGFloat
        let drift: CGFloat
    }

    static func run() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)

        var report: [String: Any] = [:]
        var failed = false

        for kase in Case.allCases where ProcessInfo.processInfo.environment["SCROLL_CASE"].map({ $0 == kase.rawValue }) ?? true {
            var readings: [String: Any] = [:]
            for arrangement in Arrangement.allCases {
                guard let reading = reading(kase, arrangement) else {
                    readings[arrangement.rawValue] = ["error": "nothing hosted a scroll view"]
                    failed = true
                    continue
                }
                readings[arrangement.rawValue] = [
                    "shortBy": rounded(reading.shortBy),
                    "drift": rounded(reading.drift),
                    "viewportBefore": rounded(reading.viewportBefore),
                    "viewportAfter": rounded(reading.viewportAfter),
                    "gapSwiftUIReports": reading.gap.isFinite ? rounded(reading.gap) : NSNull(),
                    "steps": reading.trail.map {
                        ["step": $0.name, "shortBy": rounded($0.shortBy), "drift": rounded($0.drift)]
                    },
                    "held": reading.held,
                ]
                if arrangement == .scroller { failed = failed || !reading.held }
            }
            report[kase.rawValue] = readings
        }

        report["passed"] = !failed
        let data = try? JSONSerialization.data(withJSONObject: report,
                                               options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data ?? Data())
        FileHandle.standardOutput.write(Data("\n".utf8))
        return failed ? 1 : 0
    }

    // MARK: - Driving

    /// Nil where the stage never produced a scroll view to read. Answered rather
    /// than exited on, because this is called from the test bundle as well as
    /// from the command line, and a process that exits takes the other thousand
    /// tests with it.
    static func reading(_ kase: Case, _ arrangement: Arrangement) -> Reading? {
        let script = script(for: kase)
        guard let staged = stage(arrangement, underTitlebar: script.underTitlebar) else { return nil }
        defer { dismiss(staged.window) }

        script.opening(staged.stage)
        settle(staged)

        var origin = place(staged.scroll).offset
        if script.scrollsBack { origin = scroll(staged.scroll, by: -300) }
        if script.returnsToBottom { origin = scroll(staged.scroll, by: 300) }
        let before = place(staged.scroll)

        var trail: [Step] = []
        for step in script.steps {
            // Before the change rather than after it, so a step that does both
            // can hand SwiftUI the two at once. Read the other way round they
            // arrive as separate readings, and the case that is only wrong when
            // they are coalesced passes without ever staging it.
            if step.scrollsBy != 0 {
                let moved = scroll(staged.scroll, by: step.scrollsBy, spins: step.scrollSettles)
                if !script.keepsOrigin { origin = moved }
            }
            step.change(staged.stage)
            if step.pressesEnd { pressEnd(in: staged) }
            if step.resizesBy != 0 { resize(staged.window, by: step.resizesBy) }
            settle(staged, spins: step.settles)
            let at = place(staged.scroll)
            trail.append(
                Step(name: step.name, shortBy: at.shortBy, drift: at.offset - origin)
            )
        }
        let after = place(staged.scroll)

        var reading = Reading(
            shortBy: after.shortBy,
            drift: after.offset - origin,
            viewportBefore: before.visible,
            viewportAfter: after.visible,
            gap: staged.stage.gap,
            trail: trail
        )
        reading.held = script.judge(reading)
        return reading
    }

    /// What a case does, and what would make it right. More than one step where
    /// the question is what the pane does *next*: a mechanism that answers a
    /// change and then can't answer the one after it reads as working from any
    /// single reading.
    private struct Script {
        var opening: (ScrollStage) -> Void = { _ in }
        var scrollsBack = false
        var underTitlebar = false
        /// Steps leave `drift` measured from here rather than from the place the
        /// reader went, for a case where they go somewhere else in between.
        var keepsOrigin = false
        var returnsToBottom = false
        var steps: [Move] = []
        var judge: (Reading) -> Bool
    }

    /// One thing happening to the pane.
    private struct Move {
        var name: String
        var change: (ScrollStage) -> Void = { _ in }
        var resizesBy: CGFloat = 0
        /// The reader moving mid-script. The drift is measured from where this
        /// leaves them, since what is being asked after it is what becomes of
        /// the place they just took.
        var scrollsBy: CGFloat = 0
        /// How long the move is left before the step's own change lands on top
        /// of it. Zero puts both in one reading, which is how a reader scrolling
        /// through a reply that is still being written arrives.
        var scrollSettles = 8
        /// How long the pane is left to settle before it is read. Short where
        /// the reading is about changes landing on top of each other, which is
        /// how a submit arrives and is not how anything else here does.
        var settles = 12
        /// The way back to the end pressed, after the step's change.
        var pressesEnd = false
    }

    /// Left at the bottom of the transcript, which is what a case asks for
    /// unless the reader had gone somewhere else.
    private static let flush: (Reading) -> Bool = { abs($0.shortBy) <= TranscriptColumn.slack }

    /// Left exactly where they were, which is what the other cases ask for.
    private static let stayedPut: (Reading) -> Bool = { abs($0.drift) <= TranscriptColumn.slack }

    /// At the bottom after every step rather than only at the end of them. What
    /// a case with more than one step is for: a pane that answers a change and
    /// then can't answer the next reads as working from the last reading alone.
    private static let flushThroughout: (Reading) -> Bool = { reading in
        reading.trail.allSatisfy { abs($0.shortBy) <= TranscriptColumn.slack }
    }

    private static func script(for kase: Case) -> Script {
        switch kase {
        case .opens:
            return Script(
                steps: [Move(name: "opens")],
                judge: flush
            )
        case .stripAppears:
            return Script(steps: [Move(name: "strip", change: { $0.strip = true })], judge: flush)
        case .stripAppearsWithThinking:
            return Script(
                steps: [Move(name: "stripAndThinking", change: {
                    $0.strip = true
                    $0.thinking = true
                })],
                judge: flush
            )
        case .submits:
            return Script(
                opening: { $0.composerLines = 4 },
                steps: [
                    Move(name: "sent", change: { $0.sends += 1; $0.composerLines = 1 }),
                    Move(name: "stripAndThinking", change: { $0.strip = true; $0.thinking = true }),
                    Move(name: "promptLands", change: { $0.turns += 1 }),
                ],
                judge: flushThroughout
            )
        case .submitsFromUpTheConversation:
            return Script(
                scrollsBack: true,
                steps: [
                    Move(name: "sent", change: { $0.sends += 1 }),
                    Move(name: "stripAndThinking", change: { $0.strip = true; $0.thinking = true }),
                    Move(name: "promptLands", change: { $0.turns += 1 }),
                    Move(name: "replyLands", change: { $0.turns += 1; $0.thinking = false }),
                ],
                judge: flushThroughout
            )
        case .sendsAfterAWindowDrag:
            return Script(
                steps: [
                    Move(name: "dragged", resizesBy: -120),
                    Move(name: "sent", change: { $0.sends += 1 }),
                    Move(name: "stripAndThinking", change: { $0.strip = true; $0.thinking = true }),
                    Move(name: "promptLands", change: { $0.turns += 1 }),
                ],
                // From the send: what the drag itself leaves behind is
                // `aTurnAfterAWindowDrag`'s reading, and is not this one's.
                judge: { reading in
                    reading.trail
                        .drop { $0.name != "sent" }
                        .allSatisfy { abs($0.shortBy) <= TranscriptColumn.slack }
                }
            )
        case .scrolledBackAfterASend:
            return Script(
                steps: [
                    Move(name: "sent", change: { $0.sends += 1; $0.strip = true }),
                    // As close to one reading as this can be driven: the two
                    // still arrive separately, since the clip view's move is
                    // delivered ahead of anything the layout does. What makes
                    // them safe together is that the hold is released on the
                    // offset, which a write doesn't move.
                    Move(
                        name: "readsBack",
                        change: { $0.turns += 1 },
                        scrollsBy: -300,
                        scrollSettles: 0
                    ),
                    Move(name: "turn", change: { $0.turns += 1 }),
                    Move(name: "stripGoes", change: { $0.strip = false }),
                ],
                // From the step the reader moved on: the ones before it are
                // the pane doing what a send asks of it, and the drift they
                // carry is measured from where the reader had not yet gone.
                judge: { reading in
                    reading.trail
                        .drop { $0.name != "readsBack" }
                        .allSatisfy { abs($0.drift) <= TranscriptColumn.slack }
                }
            )
        case .anotherAgentJoins:
            return Script(
                opening: { $0.strip = true; $0.thinking = true; $0.agents = 1 },
                steps: [
                    Move(name: "sent", change: { $0.sends += 1 }),
                    Move(name: "secondAgent", change: { $0.agents = 2; $0.turns += 1 }),
                    Move(name: "thirdAgent", change: { $0.agents = 3 }),
                ],
                judge: flushThroughout
            )
        case .anotherAgentJoinsUnasked:
            return Script(
                opening: { $0.strip = true; $0.thinking = true; $0.agents = 1 },
                steps: [
                    Move(name: "secondAgent", change: { $0.agents = 2; $0.turns += 1 }),
                    Move(name: "thirdAgent", change: { $0.agents = 3 }),
                ],
                judge: flushThroughout
            )
        case .stripLeaves:
            return Script(
                opening: { $0.strip = true; $0.thinking = true },
                steps: [Move(name: "stripGoes", change: { $0.strip = false; $0.thinking = false })],
                judge: flush
            )
        case .turnLands:
            return Script(steps: [Move(name: "turn", change: { $0.turns += 1 })], judge: flush)
        case .composerGrows:
            return Script(
                steps: [Move(name: "fiveLines", change: { $0.composerLines = 5 })],
                judge: flush
            )
        case .scrolledBack:
            return Script(
                scrollsBack: true,
                steps: [Move(name: "stripAndTurn", change: { $0.strip = true; $0.turns += 1 })],
                judge: stayedPut
            )
        case .scrolledBackThroughATurn:
            return Script(
                scrollsBack: true,
                steps: [
                    Move(name: "strip", change: { $0.strip = true }),
                    Move(name: "turn", change: { $0.turns += 1 }),
                    Move(name: "stripGoes", change: { $0.strip = false }),
                    Move(name: "stripAgain", change: { $0.strip = true }),
                ],
                judge: { reading in reading.trail.allSatisfy { abs($0.drift) <= TranscriptColumn.slack } }
            )
        case .returnsToBottom:
            return Script(
                scrollsBack: true,
                returnsToBottom: true,
                steps: [Move(name: "strip", change: { $0.strip = true })],
                judge: flush
            )
        case .windowShrinks:
            return Script(steps: [Move(name: "dragged", resizesBy: -120)], judge: flush)
        case .returnsToItsPlace, .returnsToItsPlaceAfterARead:
            let read = kase == .returnsToItsPlaceAfterARead
            return Script(
                scrollsBack: true,
                keepsOrigin: true,
                steps: switches(reading: read) + [
                    Move(name: "readsTheOther", scrollsBy: -500)
                ] + switches(to: "a", turns: 12, reading: read),
                judge: { abs($0.drift) <= TranscriptColumn.slack }
            )
        case .returnsToItsPlaceAfterARowAboveShrank:
            return Script(
                opening: { $0.lead = 400 },
                scrollsBack: true,
                keepsOrigin: true,
                steps: switches(reading: false) + [
                    Move(name: "opens a shut", change: {
                        $0.lead = 0
                        $0.transcript = "a"
                        $0.turns = 12
                    })
                ],
                judge: { abs($0.drift + 400) <= TranscriptColumn.slack }
            )
        case .returnsToItsPlaceReadInPasses:
            return Script(
                scrollsBack: true,
                keepsOrigin: true,
                steps: switches(reading: true) + switches(to: "a", turns: 3, reading: true) + [
                    Move(name: "rest of a", change: { $0.turns = 12 })
                ],
                judge: { abs($0.drift) <= TranscriptColumn.slack }
            )
        case .returnsToTheTop:
            return Script(
                keepsOrigin: false,
                steps: [Move(name: "toTheTop", scrollsBy: -100_000)]
                    + switches(reading: false) + switches(to: "a", turns: 12, reading: false),
                judge: { abs($0.drift) <= TranscriptColumn.slack && $0.shortBy > TranscriptColumn.slack }
            )
        case .jumpsToTheEnd:
            return Script(
                opening: { $0.turns = 30 },
                steps: [
                    Move(name: "atTheEnd", pressesEnd: true),
                    Move(name: "aLineUp", scrollsBy: -40, pressesEnd: true),
                    Move(name: "toTheTop", scrollsBy: -100_000, pressesEnd: true),
                    Move(name: "strip", change: { $0.strip = true }),
                    Move(name: "turn", change: { $0.turns += 1 }),
                ],
                judge: { reading in
                    // A line up is too near the end for the button, so the
                    // click lands on the transcript and nothing moves.
                    abs((reading.shortBy(after: "aLineUp") ?? 0) - 40) <= TranscriptColumn.slack
                        && reading.trail.dropFirst(2).allSatisfy { abs($0.shortBy) <= TranscriptColumn.slack }
                }
            )
        case .returnsWhenItsRowIsGone:
            return Script(
                opening: { $0.composerLines = 4 },
                scrollsBack: true,
                keepsOrigin: true,
                steps: switches(reading: false) + [
                    Move(name: "opens a renamed", change: {
                        $0.renamed = true
                        $0.transcript = "a"
                        $0.turns = 12
                    }),
                    Move(name: "sent", change: { $0.sends += 1; $0.composerLines = 1 }),
                    Move(name: "stripAndThinking", change: { $0.strip = true; $0.thinking = true }),
                ],
                judge: { reading in
                    abs(reading.trail.first { $0.name == "opens a renamed" }?.drift ?? .infinity)
                        <= TranscriptColumn.slack
                        && abs(reading.shortBy) <= TranscriptColumn.slack
                }
            )
        case .opensAnotherAtItsEnd:
            return Script(scrollsBack: true, steps: switches(reading: false), judge: flush)
        case .returnsToTheEndItGrew:
            return Script(
                steps: switches(reading: false)
                    + [Move(name: "readsTheOther", scrollsBy: -500)]
                    + switches(to: "a", turns: 14, reading: false),
                judge: flush
            )
        case .opensUnderTheTitlebar:
            return Script(underTitlebar: true, steps: switches(reading: true), judge: flush)
        case .aTurnAfterAWindowDrag:
            return Script(
                steps: [
                    Move(name: "dragged", resizesBy: -120),
                    Move(name: "strip", change: { $0.strip = true }),
                    Move(name: "turn", change: { $0.turns += 1 }),
                    Move(name: "stripGoes", change: { $0.strip = false }),
                    Move(name: "stripAgain", change: { $0.strip = true }),
                ],
                judge: flushThroughout
            )
        }
    }

    /// The pane taken to another transcript. Read again, the column goes for a
    /// beat while it is; kept, the new content lands in the one already there.
    private static func switches(to transcript: String = "b", turns: Int = 30, reading: Bool) -> [Move] {
        let lands = Move(name: "opens \(transcript)", change: {
            $0.cleared = false
            $0.transcript = transcript
            $0.turns = turns
        })
        guard reading else { return [lands] }
        return [Move(name: "reads \(transcript)", change: { $0.cleared = true }), lands]
    }

    /// What the scroll view is showing: how far down it is, how tall the
    /// viewport is, and — the reading everything here turns on — how far the end
    /// of the transcript is from the bottom of it.
    private struct Place {
        let offset: CGFloat
        let visible: CGFloat
        let content: CGFloat

        var shortBy: CGFloat { max(0, content - visible) - offset }
    }

    private static func place(_ scroll: NSScrollView) -> Place {
        Place(
            offset: scroll.contentView.bounds.origin.y,
            visible: scroll.contentView.bounds.height,
            content: scroll.documentView?.frame.height ?? 0
        )
    }

    /// Scrolled by hand, through the clip view rather than by asking SwiftUI —
    /// the reading is what becomes of a place the *reader* put the transcript
    /// in, and SwiftUI is the thing being measured. The pumps after it are
    /// load-bearing: SwiftUI hears the clip view move a runloop turn later, and
    /// a change landing before it has heard reads as one arriving on a reader
    /// who never left the bottom.
    ///
    /// A wheel event through the window was tried instead, to drive the gesture
    /// path rather than the programmatic one, and does not arrive: an offscreen
    /// window gets the event and its scroll view does not move (`scrolledBack`
    /// came back with the reader still at the end). That is what rules
    /// `onScrollPhaseChange` out as the signal for whether a *reader* moved —
    /// it reports `idle → idle` and nothing else for everything this can drive,
    /// so a mechanism resting on it would be one nothing here could measure.
    private static func scroll(
        _ scroll: NSScrollView,
        by points: CGFloat,
        spins: Int = 8
    ) -> CGFloat {
        let target = max(0, scroll.contentView.bounds.origin.y + points)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
        spin(times: spins)
        return scroll.contentView.bounds.origin.y
    }

    /// The container change that arrives from outside the app's own drawing.
    /// In steps with the runloop turning between them, which is how a drag on
    /// the window's edge arrives — one `setFrame` of the whole distance is a
    /// jump no user can make.
    private static func resize(_ window: NSWindow, by points: CGFloat) {
        for _ in 0..<4 {
            var frame = window.frame
            frame.size.height += points / 4
            window.setFrame(frame, display: true)
            spin(times: 4)
        }
    }

    // MARK: - The stage

    private struct Pane: View {
        @Bindable var stage: ScrollStage
        let arrangement: Arrangement
        let selection: TranscriptSelection

        var body: some View {
            VStack(spacing: 0) {
                // The probe's own reading of the geometry the mechanism gates
                // on, so the two can be held against each other.
                column
                    .onScrollGeometryChange(for: CGFloat.self) { ScrollProbe.gap(below: $0) }
                        action: { _, gap in stage.gap = gap }
                Divider()
                // With something to press, since that is the strip a working
                // session draws and the Stop button is a third of its height.
                RunningStrip(
                    agents: ScrollStage.agents(stage.agents),
                    isWorking: stage.strip,
                    handedOverAt: Date(),
                    interrupt: {}
                )
                composer
            }
            .environment(\.transcriptSelection, selection)
        }

        @ViewBuilder
        private var column: some View {
            switch arrangement {
            case .scroller:
                if stage.cleared {
                    Color.clear
                } else {
                    TranscriptColumn(
                        rows: rows,
                        sends: stage.sends,
                        transcript: stage.transcript,
                        places: stage.places
                    )
                }
            case .anchorAlone:
                control
            }
        }

        /// The pane as it was before the column: a SwiftUI scroll view with
        /// the bottom anchor. Written out rather than shared, because what it
        /// is for is being the shape the pane *doesn't* have.
        private var control: some View {
            GeometryReader { pane in
                ScrollView {
                    turns
                        .frame(maxWidth: ChromeMetrics.readingMeasure, alignment: .leading)
                        .padding(ChromeMetrics.readingInset)
                        .frame(maxWidth: .infinity, minHeight: pane.size.height, alignment: .top)
                }
                .lineSpacing(ChromeMetrics.readingLead)
                .defaultScrollAnchor(.bottom)
            }
        }

        /// The same turns as the column's rows: the prompts and replies drawn
        /// natively, as the pane draws them, and the rest in SwiftUI.
        private var rows: [ColumnRow] {
            let base = "\(stage.transcript)\(stage.renamed ? "'" : "")"
            var rows: [ColumnRow] = []
            func gap() -> CGFloat { rows.isEmpty ? 0 : ChromeMetrics.itemGap }
            // Always there, as the spacer was at the head of the first turn,
            // and at nothing tall when no row is standing open.
            rows.append(ColumnRow(
                id: "\(base)-lead", content: ["lead", "\(stage.lead)"].hashValue, place: -1,
                view: AnyView(Color.clear.frame(height: stage.lead))
            ))
            let reply = Markdown.blocks(in: Self.reply)
            for turn in 0..<stage.turns {
                let promptLead = gap()
                rows.append(ColumnRow(
                    id: "\(base)-\(turn)-p", content: ["prompt", "\(turn)", "\(promptLead)"].hashValue, place: turn * 2,
                    view: AnyView(Prompt(text: "turn \(turn)").padding(.top, promptLead)),
                    native: .prompt("turn \(turn)", waiting: false), lead: promptLead
                ))
                rows.append(ColumnRow(
                    id: "\(base)-\(turn)-r", content: ["reply"].hashValue, place: turn * 2 + 1,
                    view: AnyView(MarkdownText(blocks: reply).padding(.top, ChromeMetrics.itemGap)),
                    native: .reply(reply), lead: ChromeMetrics.itemGap
                ))
            }
            if stage.thinking {
                rows.append(ColumnRow(
                    id: "\(base)-thinking", content: ["thinking"].hashValue, place: 1_000_000,
                    view: AnyView(WorkingLine(label: "Thinking…").padding(.top, ChromeMetrics.itemGap))
                ))
            }
            return rows
        }

        private var turns: some View {
            VStack(alignment: .leading, spacing: ChromeMetrics.itemGap) {
                ForEach(0..<stage.turns, id: \.self) { turn in
                    VStack(alignment: .leading, spacing: ChromeMetrics.itemGap) {
                        if turn == 0 { Color.clear.frame(height: stage.lead) }
                        Prompt(text: "turn \(turn)")
                            .selectionIndex(turn * 2)
                        MarkdownText(blocks: Markdown.blocks(in: Self.reply))
                            .selectionIndex(turn * 2 + 1)
                    }
                }
                if stage.thinking { WorkingLine(label: "Thinking…") }
            }
        }

        /// Standing in for the composer, which needs a whole store to draw. What
        /// the transcript feels is a sibling getting taller, and a text field
        /// taking its fifth line is that.
        private var composer: some View {
            Text(String(repeating: "typed\n", count: stage.composerLines)
                .trimmingCharacters(in: .newlines))
                .font(ChromeType.Reading.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ChromeMetrics.readingInset)
        }

        private static let reply = """
            The transcript is read from the end, and the end is where the pane \
            keeps it. A turn runs a few lines, which is what makes the strip's \
            twenty-odd points worth a reading of their own.
            """
    }

    @MainActor
    private struct Staged {
        let window: NSWindow
        let stage: ScrollStage

        /// Looked up each time, since a switch builds a new one.
        var scroll: NSScrollView {
            let scrollers: [NSScrollView] = found(in: window.contentView ?? NSView())
            return scrollers.first ?? NSScrollView()
        }
    }

    /// Nil where nothing hosted a scroll view — a window server that won't have
    /// us, or a column that has stopped being one. The caller decides what that
    /// is worth: the command line exits, a test fails.
    private static func stage(_ arrangement: Arrangement, underTitlebar: Bool = false) -> Staged? {
        let stage = ScrollStage()
        let window = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: 700, height: 600),
            styleMask: underTitlebar ? [.titled, .fullSizeContentView] : [.titled],
            backing: .buffered,
            defer: false
        )
        if underTitlebar {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        // Off every screen and invisible with it, the way the selection probe
        // stages one: AppKit pulls a titled window back onto a screen.
        window.alphaValue = 0
        window.contentView = NSHostingView(
            rootView: Pane(
                stage: stage,
                arrangement: arrangement,
                selection: TranscriptSelection()
            )
            .ignoresSafeArea(.container, edges: underTitlebar ? .top : [])
        )
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        spin(times: 12)

        let scrollers: [NSScrollView] = found(in: window.contentView ?? NSView())
        guard !scrollers.isEmpty else {
            dismiss(window)
            return nil
        }
        return Staged(window: window, stage: stage)
    }

    /// Taken down rather than only hidden. The strip's clock is a `TimelineView`
    /// ticking once a second and a window merely ordered out keeps its whole
    /// tree ticking, so every stage left standing is another one competing for
    /// the runloop the next stage is being settled on.
    private static func dismiss(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
    }

    private static func settle(_ staged: Staged, spins: Int = 12) {
        staged.window.contentView?.layoutSubtreeIfNeeded()
        spin(times: spins)
    }

    /// A click where the button sits, sent to the window. The accessibility
    /// tree would name it, but SwiftUI builds none for a window nobody is
    /// reading, which this one is.
    private static func pressEnd(in staged: Staged) {
        let scroll = staged.scroll
        let frame = scroll.convert(scroll.bounds, to: nil)
        let spot = NSPoint(
            x: frame.midX,
            y: frame.minY + ChromeMetrics.readingInset + JumpToEnd.size / 2
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: spot,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: staged.window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            staged.window.sendEvent(event)
            spin(times: 2)
        }
    }

    private static func found<Kind: NSView>(in view: NSView) -> [Kind] {
        var kind: [Kind] = []
        if let match = view as? Kind { kind.append(match) }
        for child in view.subviews { kind += found(in: child) }
        return kind
    }

    private static func spin(times: Int) {
        for _ in 0..<times {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    /// How far the end of the content sits below the bottom of the viewport,
    /// as SwiftUI reports it, for the control.
    static func gap(below geometry: ScrollGeometry) -> CGFloat {
        geometry.contentSize.height + geometry.contentInsets.bottom
            - geometry.contentOffset.y - geometry.containerSize.height
    }

    private static func rounded(_ value: CGFloat) -> Double {
        (Double(value) * 10).rounded() / 10
    }
}

/// Enough of a session pane to have the geometry the reading is about: a
/// transcript over a divider, the real running strip, and something under it
/// that grows the way the composer does. The strip is the real one because its
/// height is the whole of what the transcript loses.
@MainActor
@Observable
final class ScrollStage {
    var turns = 12
    var strip = false

    /// Agents out, which the strip draws a row each for. The rows are what the
    /// transcript loses when one is sent, and a session sends them mid-turn —
    /// long after the strip itself arrived.
    var agents = 0
    var thinking = false
    var composerLines = 1

    /// What the composer would have counted. Bumping it is the probe's way of
    /// hitting return, and it is the only thing here that stands for something
    /// the reader did rather than something the layout did.
    var sends = 0

    /// The last gap SwiftUI reported below the viewport, which is the number the
    /// mechanism decides on.
    var gap: CGFloat = .nan

    var transcript = "a"

    /// The column taken down, as it is while a switch reads a transcript afresh.
    var cleared = false

    /// Extra height on the first turn, standing in for a row left open.
    var lead: CGFloat = 0

    /// Every row under another id, standing in for rows regrouped while away.
    var renamed = false

    @ObservationIgnored let places = TranscriptPlaces()

    /// Calls to hang the strip's agent rows on. Real ones, since what is being
    /// measured is the height of the row the transcript gives up for each.
    static func agents(_ count: Int) -> [ToolCall] {
        (0..<count).map { which in
            ToolCall(
                id: "agent-\(which)",
                name: "Task",
                input: .object(["description": .string("reading the transcript")]),
                startedAt: Date()
            )
        }
    }
}
