import XCTest
@testable import DexCore

final class SessionDigestTests: XCTestCase {

    private func digest(_ lines: String...) -> SessionDigest? {
        SessionDigestReader.digest(in: lines.map { Data($0.utf8) })
    }

    private let titled = #"{"type":"ai-title","aiTitle":"Restore session titles","sessionId":"s1"}"#
    private let renamed = #"{"type":"ai-title","aiTitle":"architecture audit","sessionId":"s1"}"#
    private let reply = #"{"type":"assistant","uuid":"b","message":{"content":[{"type":"text","text":"done"}]}}"#
    private let call = #"{"type":"assistant","uuid":"c","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#
    private let result = #"{"type":"user","uuid":"d","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
    private let prompt = #"{"type":"user","uuid":"e","message":{"content":"and the tests?"}}"#

    private let narrated = #"{"type":"assistant","uuid":"f","message":{"content":[{"type":"thinking","thinking":"Clearing the cached decision now.","signature":"CAISugMKjAEIERgCKkA7Qd0QNEq8/JZfULb0i/RAM1HIGcFTrg2/oHNhgd+X5CTwZvFJIVjhQ+KvAdLbWPmV/WY0JO16q6/MxyySufmbMhFjbGF1ZGUtdGVzdC1tb2RlbDgBQgluYXJyYXRpb25aJDAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwMDAwMRIMsMtv01//m/qG8pDaGgySi2yEkqFZyDV1vOciMHsXkUffosO2VCBYuaqDljGiBj6AWQHSGfA448iWRlHvd5m51OnwGQkmngnUr5I74CraAVve79KY6yNu8fdXLqRpa0OYU+DRl/NKFKd2fIxWbuwyevWuR2/ifeG+xAf3mEZweh/8IvjL0ZJu2aurIn76q04P9kKx+FX6eeQsgjU3dTwS1FZW+PBGRYDqaVpURiMCXgGfFH4DLxMqtX0wJrhDmxtv2/zP3pIf2rrmJpK55lkvx6tyipGkm3T+gzpRlwSNcZZ48jyzINIYP00oYJYtYlmCxkGkzlWeaw7Hha4+RPx5CdL6lAL3KxMCtrpBxVFKfJHoaNzRJgXuvRo8RNlvDLfKEQkpj9y+5mhgGAE="}]}}"#
    private let reasoned = #"{"type":"assistant","uuid":"g","message":{"content":[{"type":"thinking","thinking":"They probably mean the store.","signature":"EswCCmUIDhgCKkBxSmgWfGxhcWkHTprVO4ad+wW0drclzpgqTxNK6+n+mOLcNs1+KodzVl8tSoz5aPC8MDyN5C0Mg6cSCvjOmJfAMhFjbGF1ZGUtdGVzdC1tb2RlbDgAQgh0aGlua2luZxIM/Rdwmp47Jkd6ZyktGgx/lu4kt9BZYZB6iTMiMHAt2TOS4wyoixbJ1cPoyUaSs0KO5QgQZSfa4uTdCN4XnvY5Stuy5VVk5wzew1IIgCqUARzmBv/d2Z506gA+zoMPjuM7KmRW600CV7Y0MsIyHkD1t/DbtxqNsbvQ3VmB8Z1onMoaWY/s1nuQzWYHW2umwYBXTKeMeQEG9dFQiNfZMKVquk1G3+krye+Nm+9k1OQf564NfdC7V6OG/LTD7PsnXjMRaDnfeWhrIg2XJ2sLftDFQOd6h8kGYJTKpfnxd2p4eF8Ts4cYAQ=="}]}}"#

    /// Narration is prose the server summarised, not reasoning. A turn that
    /// narrated and then asked a question has nothing else to name the row by,
    /// and left out it keeps whatever the session last said in full.
    func testNarrationCountsAsSomethingSaid() {
        XCTAssertEqual(digest(reply, narrated)?.lastMessage, "Clearing the cached decision now.")
    }

    /// The summary the CLI writes after a compaction is a user record typed by
    /// nobody, and the row kept it as its second line until someone spoke again.
    func testTheCompactionSummaryIsNotSomethingSaid() {
        let summary = #"{"type":"user","uuid":"s1","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context."}}"#
        XCTAssertEqual(digest(reply, summary)?.lastMessage, "done")
    }

    /// Reasoning still doesn't. The row is what the conversation said, and a
    /// Thought is not addressed to anyone.
    func testReasoningIsStillNotSaid() {
        XCTAssertEqual(digest(reply, reasoned)?.lastMessage, "done")
    }

    /// The reading this is all for: the CLI names the session a second or two in,
    /// and the row has said its folder name until now.
    func testTheTitleIsWhatTheCLIWrote() {
        XCTAssertEqual(digest(titled, reply)?.title, "Restore session titles")
    }

    /// The CLI rewrites its own title as the session goes, so the newest is the name.
    func testTheNewestTitleWins() {
        XCTAssertEqual(digest(titled, reply, renamed)?.title, "architecture audit")
    }

    private let chosen = #"{"type":"custom-title","customTitle":"Billing bug","sessionId":"s1"}"#

    /// The CLI re-asserts both titles together, its own after the user's, so
    /// read from the end its own comes first and must not win.
    func testAUserRenameOutranksTheCLIsTitle() {
        XCTAssertEqual(digest(titled, reply, chosen, renamed)?.title, "Billing bug")
        XCTAssertEqual(digest(titled, chosen, reply, prompt, renamed)?.title, "Billing bug")
    }

    func testTheNewestRenameWins() {
        let again = #"{"type":"custom-title","customTitle":"Billing bug, part 2","sessionId":"s1"}"#
        XCTAssertEqual(digest(chosen, reply, again, titled)?.title, "Billing bug, part 2")
    }

    func testARenameBeforeTheCLITitlesItNamesTheSession() {
        XCTAssertEqual(digest(skill, expanded, reply, chosen)?.title, "Billing bug")
    }

    /// A later window that holds only the CLI's rewritten title keeps the rename.
    func testAWindowWithoutTheRenameKeepsIt() throws {
        let earlier = try XCTUnwrap(digest(titled, chosen, reply))
        let later = try XCTUnwrap(digest(reply, renamed))
        XCTAssertEqual(later.merged(over: earlier).title, "Billing bug")
    }

    private let caveat = #"{"type":"user","uuid":"m","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat: generated by local commands.</local-command-caveat>"}}"#
    private let skill = #"{"type":"user","uuid":"k","message":{"role":"user","content":"<command-message>code-review</command-message>\n<command-name>/code-review</command-name>\n<command-args>high</command-args>"}}"#
    private let expanded = #"{"type":"user","uuid":"x","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /tmp/code-review"}]}}"#

    /// The CLI titles nothing opened with a slash command, arguments or not,
    /// until a plain prompt follows, so `/code-review` alone never gets a name.
    func testASessionOpenedWithACommandGoesByIt() {
        XCTAssertEqual(digest(skill, expanded, reply)?.title, "/code-review high")
        XCTAssertEqual(digest(caveat, skill, expanded, reply)?.title, "/code-review high")
    }

    func testTheCLIsTitleOutranksTheCommand() {
        XCTAssertEqual(digest(skill, expanded, reply, prompt, titled)?.title, "Restore session titles")
    }

    /// A plain first prompt is about to be titled by the CLI.
    func testAPlainOpeningNamesNothing() {
        XCTAssertNil(digest(prompt, skill, reply)?.title)
    }

    /// Only the file's own first lines say how it opened; a window from mid-file
    /// holds whatever command happened to come next.
    func testAWindowFromMidFileNamesNothing() {
        let tail = Data([reply, skill, reply].joined(separator: "\n").utf8)
        XCTAssertNil(SessionDigestReader.digest(in: tail, isWholeFile: false)?.title)
        let whole = Data([skill, reply].joined(separator: "\n").utf8)
        XCTAssertEqual(SessionDigestReader.digest(in: whole, isWholeFile: true)?.title, "/code-review high")
    }

    func testTheLastMessageIsWhatWasSaid() {
        XCTAssertEqual(digest(prompt, reply)?.lastMessage, "done")
    }

    /// Either side, whoever spoke last — a row right after you send shows what
    /// you asked for rather than the answer before it.
    func testYourOwnMessageCountsAsTheLastOne() {
        XCTAssertEqual(digest(reply, prompt)?.lastMessage, "and the tests?")
    }

    /// The filter the whole line rests on. A tool call and the result answering it
    /// are records of their own, and reading either as something said leaves the
    /// row showing a stack trace where the conversation should be.
    func testACallAndItsResultAreNotSaid() {
        XCTAssertEqual(digest(reply, call, result)?.lastMessage, "done")
    }

    /// A subagent's turns are its own conversation.
    func testASubagentsTurnIsNotThisConversations() {
        let sidechain = #"{"type":"assistant","uuid":"s","isSidechain":true,"message":{"content":[{"type":"text","text":"on it"}]}}"#
        XCTAssertEqual(digest(reply, sidechain)?.lastMessage, "done")
    }

    func testWhatTheCLIFeedsTheModelIsNobodysMessage() {
        let meta = #"{"type":"user","uuid":"m","isMeta":true,"message":{"content":"Caveat: the messages below"}}"#
        XCTAssertEqual(digest(reply, meta)?.lastMessage, "done")
    }

    /// A message sent mid-turn arrives wrapped in a reminder. Stripping reminders
    /// whole would lose the one thing in them that was typed, and showing the
    /// wrapper puts machinery on the row.
    func testAMidTurnMessageComesBackOutOfItsReminder() {
        let wrapped = #"{"type":"user","uuid":"w","message":{"content":"<system-reminder>The user sent a new message while you were working:\nrun the tests</system-reminder>"}}"#
        XCTAssertEqual(digest(reply, wrapped)?.lastMessage, "run the tests")
    }

    /// A reminder with nothing typed in it is machinery whole, and the row keeps
    /// showing the last thing that was actually said.
    func testAReminderWithNothingTypedInItIsSkipped() {
        let reminder = #"{"type":"user","uuid":"r","message":{"content":"<system-reminder>Plan mode is active</system-reminder>"}}"#
        XCTAssertEqual(digest(reply, reminder)?.lastMessage, "done")
    }

    /// The row draws two lines, so a paragraph is folded onto one rather than
    /// spending both on the first sentence's wrap.
    func testTheMessageIsFoldedOntoOneLine() {
        let paragraphs = #"{"type":"assistant","uuid":"p","message":{"content":[{"type":"text","text":"first\n\n  second"}]}}"#
        XCTAssertEqual(digest(paragraphs)?.lastMessage, "first second")
    }

    /// Folding takes the line breaks that gave block syntax its meaning, so the
    /// markers go with them — a `##` in the middle of a sentence is not a heading
    /// on the row, in a notification, or in the fleet.
    func testBlockSyntaxIsFoldedAwayWithItsLines() {
        XCTAssertEqual(
            SessionDigestReader.oneLine("## What changed\n- the row\n> quoted\n3. third"),
            "What changed the row quoted third"
        )
    }

    /// A fence or a rule is a line with no words of its own, so it folds to
    /// nothing rather than to its punctuation.
    func testFencesAndRulesFoldToNothing() {
        XCTAssertEqual(
            SessionDigestReader.oneLine("before\n```swift\nlet x = 1\n```\n---\nafter"),
            "before let x = 1 after"
        )
    }

    /// A fence is still a fence inside a blockquote — the quote bracket comes
    /// off first, or the fence prints literally.
    func testAQuotedFenceStillFoldsToNothing() {
        XCTAssertEqual(
            SessionDigestReader.oneLine("> ```\n> quoted code\n> ```"),
            "quoted code"
        )
    }

    /// Inline spans stay: the row renders those, and unrendered they still read
    /// as words. Stripping is for the markers that only meant anything at the
    /// start of a line.
    func testInlineSpansSurviveTheFold() {
        XCTAssertEqual(
            SessionDigestReader.oneLine("the **bold** claim in `code`"),
            "the **bold** claim in `code`"
        )
    }

    /// A year is not a list index: the ordered-list cut takes short numbers
    /// before a dot-space, not sentences that open with a date.
    func testASentenceStartingWithAYearIsNotAListItem() {
        XCTAssertEqual(
            SessionDigestReader.oneLine("2026. That was the year."),
            "2026. That was the year."
        )
    }

    /// The inline spans the fold kept are rendered, not shown as syntax.
    func testInlineMarkdownRendersItsSpans() {
        let rendered = SessionDigestReader.inlineMarkdown("the **bold** claim")
        XCTAssertEqual(String(rendered.characters), "the bold claim")
    }

    /// A tap on the row opens the pane, so nothing in the preview is allowed to
    /// be a link that would take the tap instead.
    func testInlineMarkdownDisarmsLinks() {
        let rendered = SessionDigestReader.inlineMarkdown("see [the docs](https://example.com)")
        XCTAssertEqual(String(rendered.characters), "see the docs")
        XCTAssertTrue(rendered.runs.allSatisfy { $0.link == nil })
    }

    /// Nothing whole was read, which is the caller's cue to look further back
    /// rather than to answer — a window can land inside one pasted record.
    func testAWindowThatReadNothingWholeAnswersNothing() {
        XCTAssertNil(digest(#"{"type":"assis"#))
    }

    /// A file with records but no title is not a reason to widen: a session that
    /// has not been given one yet would send every read to the far window.
    func testAnUntitledSessionStillAnswers() {
        let digest = digest(reply)
        XCTAssertNotNil(digest)
        XCTAssertNil(digest?.title)
        XCTAssertEqual(digest?.lastMessage, "done")
    }

    // MARK: - Off the file itself

    func testAStopNamesWhatItCanceled() {
        let stop = #"{"type":"user","uuid":"s","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        let cut = #"{"type":"user","uuid":"x","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"[Request interrupted by user for tool use]","is_error":true}]}}"#
        XCTAssertEqual(digest(prompt, reply, call, cut, stop)?.lastMessage, "Bash canceled")
    }

    func testAStopWithNoCallCancelsTheResponse() {
        let stop = #"{"type":"user","uuid":"s","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        XCTAssertEqual(digest(prompt, stop)?.lastMessage, "Response canceled")
    }

    private func write(_ lines: String..., to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAFileIsReadFromItsEnd() throws {
        let directory = try temporaryDirectory()
        let url = try write(titled, prompt, reply, to: directory)

        let digest = SessionDigestReader.digest(at: url)
        XCTAssertEqual(digest.title, "Restore session titles")
        XCTAssertEqual(digest.lastMessage, "done")
    }

    /// A record is as long as whatever was pasted into it, so a window can land
    /// entirely inside one and hold no whole record at all. That is the file most
    /// likely to have a title worth reading, so a miss widens rather than answers.
    func testAWindowInsideOneRecordLooksFurtherBack() throws {
        let directory = try temporaryDirectory()
        let padded = #"{"type":"assistant","uuid":"g","message":{"content":[{"type":"text","text":"\#(String(repeating: "x", count: 4_000))"}]}}"#
        let url = try write(titled, padded, to: directory)

        XCTAssertNil(SessionDigestReader.digest(at: url, windows: [512]).title)
        XCTAssertEqual(
            SessionDigestReader.digest(at: url, windows: [512, 4_000_000]).title,
            "Restore session titles"
        )
    }

    /// A skill can run long enough to leave its opening behind the window, and
    /// the command is still the only name the session has.
    func testALongSessionStillFindsItsOpeningCommand() throws {
        let directory = try temporaryDirectory()
        let padded = #"{"type":"assistant","uuid":"g","message":{"content":[{"type":"text","text":"\#(String(repeating: "x", count: 4_000))"}]}}"#
        let url = try write(skill, padded, reply, to: directory)

        XCTAssertEqual(SessionDigestReader.digest(at: url, windows: [4_100]).title, "/code-review high")
    }

    /// A window that misses the CLI's title falls back to the command, and that
    /// must not merge over the title an earlier reading found.
    func testTheCommandNeverMergesOverTheCLIsTitle() {
        let earlier = digest(skill, expanded, reply, prompt, titled)!
        let later = digest(skill, reply)!
        XCTAssertEqual(later.title, "/code-review high")
        XCTAssertEqual(later.merged(over: earlier).title, "Restore session titles")
        XCTAssertEqual(earlier.merged(over: later).title, "Restore session titles")
    }

    /// The reading the index is for: a session runs on past its title, and a row
    /// that answered with only what this window held would blank its own name.
    func testTheIndexKeepsTheTitleAfterItScrollsPast() throws {
        let directory = try temporaryDirectory()
        let index = SessionDigestIndex()

        let named = try write(titled, reply, to: directory)
        XCTAssertEqual(
            index.digest(sessionID: "s1", locate: { named }, lastWrite: { _ in Date(timeIntervalSince1970: 1) }).title,
            "Restore session titles"
        )

        try (prompt + "\n").write(to: named, atomically: true, encoding: .utf8)
        let read = index.digest(
            sessionID: "s1",
            locate: { named },
            lastWrite: { _ in Date(timeIntervalSince1970: 2) }
        )
        XCTAssertEqual(read.title, "Restore session titles")
        XCTAssertEqual(read.lastMessage, "and the tests?")
    }

    /// The list rebuilds on every host event and reads the file off the main
    /// thread afterwards, so what a rebuild draws is the last reading, without
    /// going to disk — nothing until one has been taken.
    func testTheLatestReadingIsAnsweredWithoutTheFile() throws {
        let directory = try temporaryDirectory()
        let index = SessionDigestIndex()
        XCTAssertNil(index.latest(sessionID: "s1"))

        let named = try write(titled, reply, to: directory)
        _ = index.digest(sessionID: "s1", locate: { named }, lastWrite: { _ in Date(timeIntervalSince1970: 1) })
        XCTAssertEqual(index.latest(sessionID: "s1")?.title, "Restore session titles")

        try FileManager.default.removeItem(at: named)
        XCTAssertEqual(index.latest(sessionID: "s1")?.title, "Restore session titles")
    }

    /// A session that changes its own directory is filed under a second folder,
    /// its first file left behind complete. A row that kept reading the old one
    /// would freeze at the moment of the move with nothing on screen to say so.
    func testATranscriptRefiledUnderAnotherFolderIsFoundAgain() throws {
        let directory = try temporaryDirectory()
        let index = SessionDigestIndex()
        let start = Date(timeIntervalSince1970: 1_000)

        let before = try write(titled, reply, to: directory)
        _ = index.digest(
            sessionID: "s1",
            locate: { before },
            lastWrite: { _ in start },
            now: start
        )

        let after = try write(titled, prompt, to: directory)
        let moved = index.digest(
            sessionID: "s1",
            locate: { after },
            lastWrite: { _ in start.addingTimeInterval(1) },
            now: start.addingTimeInterval(SessionDigestIndex.relocateAfter + 1)
        )
        XCTAssertEqual(moved.lastMessage, "and the tests?")
    }

    /// An unchanged file is never read twice — the list merges hosted rows on
    /// every event the host sends, which on a working session is constant.
    func testAnUnchangedFileIsNotReadAgain() throws {
        let directory = try temporaryDirectory()
        let index = SessionDigestIndex()
        let stamp = Date(timeIntervalSince1970: 1)

        let file = try write(titled, reply, to: directory)
        _ = index.digest(sessionID: "s1", locate: { file }, lastWrite: { _ in stamp })

        try (prompt + "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            index.digest(sessionID: "s1", locate: { file }, lastWrite: { _ in stamp }).lastMessage,
            "done",
            "the write time did not move, so nothing should have been read"
        )
    }

    /// Locating a transcript lists every folder under `projects` — 1.5ms against
    /// 233 of them — and the list rebuilds its hosted rows on every host event,
    /// not only the one that changed.
    func testTheFileIsFoundOnceRatherThanOnEveryRead() throws {
        let directory = try temporaryDirectory()
        let index = SessionDigestIndex()
        let file = try write(titled, reply, to: directory)

        var searches = 0
        let locate: () -> URL? = { searches += 1; return file }
        let stamp = Date(timeIntervalSince1970: 1)
        for _ in 0..<5 {
            _ = index.digest(sessionID: "s1", locate: locate, lastWrite: { _ in stamp }, now: stamp)
        }
        XCTAssertEqual(searches, 1)
    }

    /// A file that has gone is looked for again rather than answered from a path
    /// nothing is writing to any more.
    func testAFileThatGoesAwayIsLookedForAgain() throws {
        let directory = try temporaryDirectory()
        let index = SessionDigestIndex()
        let stamp = Date(timeIntervalSince1970: 1)
        let first = try write(titled, reply, to: directory)

        _ = index.digest(sessionID: "s1", locate: { first }, lastWrite: { _ in stamp }, now: stamp)
        try FileManager.default.removeItem(at: first)

        let moved = try write(titled, prompt, to: directory)
        XCTAssertEqual(
            index.digest(
                sessionID: "s1",
                locate: { moved },
                lastWrite: { _ in stamp.addingTimeInterval(1) },
                now: stamp
            ).lastMessage,
            "and the tests?"
        )
    }

    /// The title scrolls out of the window long before the session ends, and a
    /// reading that lost it would blank the row's title on the next write.
    func testALaterReadingKeepsTheTitleItNoLongerSees() {
        let first = SessionDigest(title: "Restore session titles", lastMessage: "done")
        let second = SessionDigest(title: nil, lastMessage: "on it")

        let merged = second.merged(over: first)
        XCTAssertEqual(merged.title, "Restore session titles")
        XCTAssertEqual(merged.lastMessage, "on it")
    }
}
