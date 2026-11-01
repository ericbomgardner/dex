import XCTest
@testable import DexCore

final class ToolCallTests: XCTestCase {

    private func call(_ name: String, _ input: [String: JSONValue]) -> ToolCall {
        ToolCall(id: "t1", name: name, input: .object(input))
    }

    func testFileToolsSummariseToTheirPath() {
        for name in ["Read", "Write", "Edit", "MultiEdit", "NotebookEdit"] {
            let tool = call(name, ["file_path": .string("/a/b/c/d/e/Thing.swift")])
            XCTAssertEqual(tool.summary, ".../e/Thing.swift".replacingOccurrences(of: "...", with: "…"))
        }
    }

    func testBashSummarisesToTheCommand() {
        XCTAssertEqual(call("Bash", ["command": .string("swift build")]).summary, "swift build")
    }

    /// The command leads in the conversation and the model's own line leads away
    /// from it: a row over the composer is there to say what is still out, and
    /// two rows in it should not be named by two different rules.
    func testPurposeLeadsWithWhatTheModelSaidTheCallWasFor() {
        let tool = call("Bash", [
            "command": .string("swift test > /tmp/swifttest.log 2>&1"),
            "description": .string("Run full test suite"),
        ])
        XCTAssertEqual(tool.purpose, "Run full test suite")
        XCTAssertEqual(tool.summary, "swift test > /tmp/swifttest.log 2>&1")
    }

    func testPurposeFallsBackToTheSummaryWhenNothingSaysWhatItIsFor() {
        let tool = call("Bash", ["command": .string("swift build")])
        XCTAssertEqual(tool.purpose, "swift build")
        XCTAssertNil(call("Bash", [:]).purpose)
    }

    /// An agent has always been named this way — the point of the property is
    /// that a command now is too.
    func testAnAgentsPurposeIsTheBriefItWasGiven() {
        let tool = call("Task", [
            "description": .string("Review the branch diff"),
            "subagent_type": .string("pre-merge-review"),
        ])
        XCTAssertEqual(tool.purpose, "Review the branch diff")
    }

    func testAMultiLineCommandIsCutToItsFirstLine() {
        let tool = call("Bash", ["command": .string("swift build\nswift test")])
        XCTAssertEqual(tool.summary, "swift build …")
    }

    func testTheFullSummaryKeepsTheWholeCommand() {
        let script = "cd /tmp && python3 - <<'EOF'\nimport json\nprint(json.dumps({}))\nEOF"
        let tool = call("Bash", ["command": .string(script)])
        XCTAssertEqual(tool.fullSummary, script)
        XCTAssertEqual(tool.summary, "cd /tmp && python3 - <<'EOF' …",
                       "the list keeps its one line")
    }

    /// Only a command is ever shortened, so everything else answers the same
    /// either way — and the card asks for the full one whatever the tool is.
    func testEverythingElseSummarisesTheSameBothWays() {
        for tool in [
            call("Read", ["file_path": .string("/a/b/c/d/e/Thing.swift")]),
            call("Grep", ["pattern": .string("TODO"), "path": .string("/tmp/x")]),
            call("Task", ["description": .string("Review the diff")]),
            call("Bash", ["description": .string("Run the suite")]),
            call("Odd", [:]),
        ] {
            XCTAssertEqual(tool.fullSummary, tool.summary)
        }
    }

    func testBashFallsBackToItsDescription() {
        let tool = call("Bash", ["description": .string("Run the suite")])
        XCTAssertEqual(tool.summary, "Run the suite")
    }

    func testSearchToolsPairThePatternWithThePath() {
        let tool = call("Grep", ["pattern": .string("TODO"), "path": .string("/tmp/x")])
        XCTAssertEqual(tool.summary, "TODO  in  /tmp/x")
    }

    func testSearchWithoutAPathIsJustThePattern() {
        XCTAssertEqual(call("Glob", ["pattern": .string("**/*.swift")]).summary, "**/*.swift")
    }

    func testTodoWriteCountsWhatIsDone() {
        let todos = JSONValue.array([
            .object(["status": .string("completed")]),
            .object(["status": .string("completed")]),
            .object(["status": .string("in_progress")]),
        ])
        XCTAssertEqual(call("TodoWrite", ["todos": todos]).summary, "2/3 done")
    }

    func testAskUserQuestionReachesIntoItsQuestionList() {
        let questions = JSONValue.array([.object(["question": .string("Which one?")])])
        XCTAssertEqual(call("AskUserQuestion", ["questions": questions]).summary, "Which one?")
    }

    func testAskUserQuestionCountsTheRest() {
        let questions = JSONValue.array([
            .object(["question": .string("Which one?")]),
            .object(["question": .string("And then?")]),
        ])
        XCTAssertEqual(
            call("AskUserQuestion", ["questions": questions]).summary,
            "Which one? (+1 more)"
        )
    }

    func testAnUnknownToolBorrowsItsFirstScalarField() {
        let tool = call("SomeNewTool", ["alpha": .string("first"), "beta": .string("second")])
        XCTAssertEqual(tool.summary, "first")
    }

    func testAnUnknownToolWithNoScalarsHasNoSummary() {
        let tool = call("SomeNewTool", ["nested": .object(["a": .string("b")])])
        XCTAssertNil(tool.summary)
    }

    func testAMissingFieldLeavesNoEmptySummary() {
        XCTAssertNil(call("Read", [:]).summary)
        XCTAssertNil(call("Grep", [:]).summary)
    }

    func testNumbersAndFlagsReadAsThemselves() {
        XCTAssertEqual(call("X", ["a": .number(12)]).summary, "12")
        XCTAssertEqual(call("X", ["a": .bool(true)]).summary, "true")
    }

    func testPrettyInputIsSortedJSON() {
        let tool = call("Read", ["file_path": .string("/tmp/a"), "limit": .number(5)])
        XCTAssertEqual(
            tool.prettyInput,
            """
            {
              "file_path" : "/tmp/a",
              "limit" : 5
            }
            """
        )
    }

    func testPrettyInputIsAbsentWhenThereIsNoInput() {
        XCTAssertNil(call("Read", [:]).prettyInput)
    }

    // Questions

    private func asked(_ questions: [String], answered: String?) -> [AskedQuestion] {
        let input = JSONValue.object([
            "questions": .array(questions.map { .object(["question": .string($0)]) })
        ])
        let result = answered.map { ToolResult(text: $0, isError: false) }
        return ToolCall(id: "t1", name: "AskUserQuestion", input: input, result: result)
            .askedQuestions
    }

    func testEachQuestionPicksUpItsOwnAnswer() {
        let reply = """
        Your questions have been answered: "Which one?"="The second", \
        "And then?"="Ship it". You can now continue with these answers in mind.
        """
        let questions = asked(["Which one?", "And then?"], answered: reply)
        XCTAssertEqual(questions.map(\.question), ["Which one?", "And then?"])
        XCTAssertEqual(questions.map(\.answer), ["The second", "Ship it"])
    }

    func testAQuestionNobodyAnsweredYetHasNoAnswer() {
        XCTAssertEqual(asked(["Which one?"], answered: nil).first?.answer, nil)
    }

    func testAnAnswerIsNotBorrowedFromADifferentQuestion() {
        let reply = #"Your questions have been answered: "And then?"="Ship it"."#
        XCTAssertNil(asked(["Which one?"], answered: reply).first?.answer)
    }

    /// The dialog has room for one mockup and shows the one its cursor is on, so
    /// while a question is up there is nowhere to see the rest. The call carries
    /// all of them, and reaches the transcript once the question is answered.
    func testTheOptionsComeBackWithWhatTheyMeantAndLookedLike() {
        let input = JSONValue.object([
            "questions": .array([
                .object([
                    "question": .string("Which tab?"),
                    "options": .array([
                        .object([
                            "label": .string("Chat"),
                            "description": .string("Names what the pane shows"),
                            "preview": .string("┌──────┐\n│ Chat │"),
                        ]),
                        .object(["label": .string("Output")]),
                    ]),
                ])
            ])
        ])
        let result = ToolResult(text: #"Answered: "Which tab?"="Output"."#, isError: false)
        let question = ToolCall(id: "t1", name: "AskUserQuestion", input: input, result: result)
            .askedQuestions.first

        XCTAssertEqual(question?.options.map(\.label), ["Chat", "Output"])
        XCTAssertEqual(question?.options.first?.description, "Names what the pane shows")
        XCTAssertEqual(question?.options.first?.preview, "┌──────┐\n│ Chat │")
        XCTAssertNil(question?.options.last?.description)
        XCTAssertEqual(question?.chosen?.label, "Output")
        XCTAssertEqual(question?.isWorthOpening, true)
    }

    /// A typed answer names no option, which is what tells it from a picked one.
    func testAnAnswerNobodyOfferedPicksNoOption() {
        let input = JSONValue.object([
            "questions": .array([
                .object([
                    "question": .string("Which tab?"),
                    "options": .array([.object(["label": .string("Chat")])]),
                ])
            ])
        ])
        let result = ToolResult(text: #"Answered: "Which tab?"="something else"."#, isError: false)
        let question = ToolCall(id: "t1", name: "AskUserQuestion", input: input, result: result)
            .askedQuestions.first

        XCTAssertEqual(question?.answer, "something else")
        XCTAssertNil(question?.chosen)
    }

    /// Bare labels are already on the card; opening them again would say nothing.
    func testOptionsWithNothingUnderThemAreNotWorthOpening() {
        let input = JSONValue.object([
            "questions": .array([
                .object([
                    "question": .string("Which tab?"),
                    "options": .array([
                        .object(["label": .string("Chat")]),
                        .object(["label": .string("Output")]),
                    ]),
                ])
            ])
        ])
        let question = ToolCall(id: "t1", name: "AskUserQuestion", input: input).askedQuestions.first

        XCTAssertEqual(question?.options.count, 2)
        XCTAssertEqual(question?.isWorthOpening, false)
    }

    func testAQuestionAskedWithNoOptionsCarriesNone() {
        XCTAssertEqual(asked(["Which one?"], answered: nil).first?.options, [])
    }

    func testTheHeaderComesAlongWhenThereIsOne() {
        let input = JSONValue.object([
            "questions": .array([
                .object(["question": .string("Which one?"), "header": .string("Approach")])
            ])
        ])
        let tool = ToolCall(id: "t1", name: "AskUserQuestion", input: input)
        XCTAssertEqual(tool.askedQuestions.first?.header, "Approach")
    }

    func testTheStructuredAnswerIsPreferredToTheSentence() {
        let input = JSONValue.object([
            "questions": .array([.object(["question": .string("Which one?")])])
        ])
        let result = ToolResult(
            text: #""Which one?"="from the sentence""#,
            isError: false,
            answers: ["Which one?": "from the answers"]
        )
        let tool = ToolCall(id: "t1", name: "AskUserQuestion", input: input, result: result)
        XCTAssertEqual(tool.askedQuestions.first?.answer, "from the answers")
    }

    func testANoteComesAlongWithTheAnswer() {
        let input = JSONValue.object([
            "questions": .array([.object(["question": .string("Which one?")])])
        ])
        let result = ToolResult(
            text: "",
            isError: false,
            answers: ["Which one?": "(notes only)"],
            notes: ["Which one?": "neither, do the third thing"]
        )
        let tool = ToolCall(id: "t1", name: "AskUserQuestion", input: input, result: result)
        XCTAssertEqual(tool.askedQuestions.first?.note, "neither, do the third thing")
    }

    // Subagents

    func testDelegationIsTaskAndAgent() {
        XCTAssertTrue(call("Task", [:]).isDelegation)
        XCTAssertTrue(call("Agent", [:]).isDelegation)
        XCTAssertFalse(call("Bash", [:]).isDelegation)
    }

    func testWhatASubagentDidReadsAsOneLine() {
        let totals = SubagentTotals(toolUses: 12, tokens: 37_449, duration: 64)
        XCTAssertEqual(totals.summary, "12 tool uses · 37.4k tokens · 1m 4s")
    }

    func testOneToolUseIsNotPluralised() {
        let totals = SubagentTotals(toolUses: 1, tokens: 900, duration: 3)
        XCTAssertEqual(totals.summary, "1 tool use · 900 tokens · 3s")
    }

    func testAToolThatIsNotAQuestionAsksNothing() {
        XCTAssertTrue(call("Bash", ["command": .string("ls")]).askedQuestions.isEmpty)
        XCTAssertFalse(call("Bash", ["command": .string("ls")]).isQuestion)
    }
}
