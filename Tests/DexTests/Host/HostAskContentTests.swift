import XCTest

@testable import DexCore

/// `Fixtures/ask-question-input.json` is the input of a real `AskUserQuestion`
/// call, captured off the SDK's `canUseTool` with previews turned on. It is the
/// payload the whole sidecar exists to get hold of, so the parser is pinned to
/// it rather than to hand-written JSON.
final class HostAskContentTests: XCTestCase {

    private func questionAsk() throws -> HostAsk {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "ask-question-input", withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: "ask-question-input", withExtension: "json")
        )
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        return HostAsk(
            askId: "a1",
            key: "s1",
            kind: .question,
            toolName: "AskUserQuestion",
            input: input,
            options: []
        )
    }

    func testARealQuestionReadsBackWhole() throws {
        guard case .questions(let questions) = HostAskContent.read(try questionAsk()) else {
            return XCTFail("an AskUserQuestion should read as questions")
        }

        XCTAssertEqual(questions.count, 2)
        let first = try XCTUnwrap(questions.first)
        XCTAssertFalse(first.question.isEmpty)
        XCTAssertFalse(first.header.isEmpty)
        XCTAssertFalse(first.multiSelect)
        XCTAssertGreaterThanOrEqual(first.options.count, 2)
        XCTAssertTrue(first.options.allSatisfy { $0.detail?.isEmpty == false })
    }

    /// The reason the sidecar exists in the shape it does: the CLI draws one
    /// mockup, for whichever option its cursor is on. Here they all arrive.
    func testEveryOptionKeepsItsOwnPreview() throws {
        guard case .questions(let questions) = HostAskContent.read(try questionAsk()) else {
            return XCTFail("expected questions")
        }

        let options = questions.flatMap(\.options)
        XCTAssertGreaterThanOrEqual(options.count, 4)
        XCTAssertTrue(
            options.allSatisfy { ($0.preview?.isEmpty == false) },
            "each option carried a preview when captured; a parser that keeps only one is the bug"
        )
    }

    func testHeadersStayShortEnoughToReadAsAChip() throws {
        guard case .questions(let questions) = HostAskContent.read(try questionAsk()) else {
            return XCTFail("expected questions")
        }
        for question in questions {
            XCTAssertLessThanOrEqual(question.header.count, 12)
        }
    }

    // MARK: - What a malformed or unusual payload does

    func testAQuestionWithNoOptionsIsDroppedRatherThanShownUnanswerable() {
        let input = JSONValue.object([
            "questions": .array([
                .object(["question": .string("no way to answer this"), "options": .array([])]),
                .object([
                    "question": .string("fine"),
                    "options": .array([.object(["label": .string("Yes")])]),
                ]),
            ])
        ])
        let questions = HostQuestion.read(input)
        XCTAssertEqual(questions.map(\.question), ["fine"])
    }

    func testAMultiSelectQuestionSaysSo() throws {
        let input = JSONValue.object([
            "questions": .array([
                .object([
                    "question": .string("Which sections?"),
                    "header": .string("Sections"),
                    "multiSelect": .bool(true),
                    "options": .array([
                        .object(["label": .string("Intro"), "description": .string("Opening")])
                    ]),
                ])
            ])
        ])
        let question = try XCTUnwrap(HostQuestion.read(input).first)
        XCTAssertTrue(question.multiSelect)
        XCTAssertEqual(question.options.first?.detail, "Opening")
        XCTAssertNil(question.options.first?.preview)
    }

    func testAnythingThatIsNotAQuestionReadsAsAPermission() {
        let ask = HostAsk(
            askId: "a2",
            key: "s1",
            kind: .permission,
            toolName: "Bash",
            input: .object([
                "command": .string("rm -rf build"),
                "description": .string("clean"),
            ]),
            options: [HostAskOption(optionId: "allow_once", name: "Allow", kind: .allowOnce)]
        )

        guard case .permission(let request) = HostAskContent.read(ask) else {
            return XCTFail("expected a permission")
        }
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.summary, "rm -rf build", "the command leads, not the description")
        XCTAssertEqual(request.options.first?.kind, .allowOnce)
    }

    /// A card that showed the first line alone asked you to agree to a script
    /// whose body was behind the ellipsis.
    func testTheCardIsGivenTheWholeCommand() {
        let script = "cd /tmp && python3 - <<'EOF'\nimport glob\nprint(glob.glob('*'))\nEOF"
        let request = permission(toolName: "Bash", input: .object(["command": .string(script)]))
        XCTAssertEqual(request?.fullSummary, script)
        XCTAssertEqual(request?.summary, "cd /tmp && python3 - <<'EOF' …")
    }

    func testAToolWithNothingWorthSummarisingSaysNothing() {
        let ask = HostAsk(
            askId: "a3", key: "s1", kind: .permission, toolName: "Odd",
            input: .object(["shape": .object(["nested": .string("x")])]), options: []
        )
        guard case .permission(let request) = HostAskContent.read(ask) else {
            return XCTFail("expected a permission")
        }
        XCTAssertNil(request.summary)
    }

    /// The keys a permission used to scan for are a handful the tools happen to
    /// share, and a delegation names its work in none of them — so the card led
    /// with a tool name and said nothing about what it was agreeing to.
    func testASubjectOutsideTheCommonKeysIsStillNamed() {
        let request = permission(
            toolName: "Task",
            input: .object([
                "subagent_type": .string("pre-merge-review"),
                "description": .string("Review the diff"),
            ])
        )
        XCTAssertEqual(request?.summary, "Review the diff")
        XCTAssertEqual(request?.title, "Hand this to a subagent")
    }

    func testAToolThisDoesNotKnowIsNamedByItsOwnName() {
        let request = permission(toolName: "Odd", input: .object(["url": .string("x")]))
        XCTAssertEqual(request?.title, "Use Odd")
    }

    /// A plan is decided on the plan itself, in the transcript — so the card
    /// below the composer has to be able to tell one from a tool call.
    func testAPlanIsMarkedAsOne() {
        let plan = permission(toolName: "ExitPlanMode", input: .object(["plan": .string("# Do it")]))
        XCTAssertEqual(plan?.isPlan, true)
        XCTAssertEqual(permission(toolName: "Bash", input: .object([:]))?.isPlan, false)
    }

    private func permission(toolName: String, input: JSONValue) -> HostPermissionRequest? {
        HostAskContent
            .read(
                HostAsk(
                    askId: "a4", key: "s1", kind: .permission,
                    toolName: toolName, input: input, options: []
                )
            )
            .permissionRequest
    }
}
