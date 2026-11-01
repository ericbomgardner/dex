import XCTest

@testable import DexCore

/// `Fixtures/host-wire.jsonl` is a capture of a real host serving a real
/// session, written by `Sidecar/test/smoke.ts` under `DEX_SMOKE_DUMP`, with
/// its ids, temp folder and tool and command lists swapped for generic ones.
/// Recapture it when the host's wire moves; if the
/// SDK changes an ask's shape underneath, this is where it shows up.
///
/// Cut after the resolved defaults and before the stop, where the dump keeps
/// going:
/// the smoke run stops and resumes the session afterwards, and the `done` that
/// retires it would be read below as a turn that finished by retiring one.
final class HostProtocolTests: XCTestCase {

    private func wire(_ name: String = "host-wire", in folder: String = "Fixtures") throws -> [HostEvent] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: folder)
                ?? Bundle.module.url(forResource: name, withExtension: "jsonl")
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(HostEvent.self, from: Data($0.utf8)) }
    }

    func testEveryLineOfARealSessionDecodes() throws {
        var events = try wire()
        XCTAssertFalse(events.isEmpty)
        for event in events {
            if case .unrecognised(let type) = event {
                XCTFail("host wrote an event the app cannot read: \(type)")
            }
        }
    }

    func testWelcomeCarriesTheHandshake() throws {
        let welcome = try wire().compactMap { event -> HostWelcome? in
            if case .welcome(let welcome) = event { return welcome }
            return nil
        }.first

        let handshake = try XCTUnwrap(welcome)
        XCTAssertEqual(handshake.protocolVersion, HostProtocol.version)
        XCTAssertFalse(handshake.sdk.isEmpty)
        XCTAssertNotNil(
            handshake.sdkOnDisk,
            "a host that says only what it loaded can never be told from one that is behind"
        )
        XCTAssertTrue(handshake.modes.contains("plan"))
    }

    func testAnAskArrivesWithItsOptionsAndItsInputWhole() throws {
        let ask = try XCTUnwrap(
            try wire().compactMap { event -> HostAsk? in
                if case .ask(let ask) = event { return ask }
                return nil
            }.first
        )

        XCTAssertEqual(ask.kind, .permission)
        XCTAssertFalse(ask.toolName.isEmpty)
        XCTAssertNotNil(ask.input.objectValue, "a tool's input is an object, kept unmodelled")
        XCTAssertTrue(ask.options.contains { $0.kind == .allowOnce })
        XCTAssertTrue(ask.options.contains { $0.kind == .rejectOnce })
    }

    func testSessionInitBindsAKeyToATranscript() throws {
        let start = try XCTUnwrap(
            try wire().compactMap { event -> HostSessionInit? in
                if case .sessionInit(let start) = event { return start }
                return nil
            }.first
        )

        XCTAssertFalse(start.sessionId.isEmpty)
        XCTAssertFalse(start.key.isEmpty)
        XCTAssertFalse(start.permissionMode.isEmpty)
        XCTAssertFalse(start.tools.isEmpty)
    }

    /// The list the CLI will dispatch, which is not the list it ships: the ones
    /// that only open a panel in a terminal are left out, and that absence is
    /// the whole of what greys a row in the slash menu.
    func testSessionInitNamesTheCommandsTheCLIWillActuallyRun() throws {
        let start = try XCTUnwrap(
            try wire().compactMap { event -> HostSessionInit? in
                if case .sessionInit(let start) = event { return start }
                return nil
            }.first
        )

        let commands = try XCTUnwrap(start.commands)
        XCTAssertTrue(commands.contains("model"))
        XCTAssertFalse(commands.contains("help"))
    }

    func testATurnSettlesToIdleRatherThanDone() throws {
        let states = try wire().compactMap { event -> HostSessionState? in
            if case .sessionStatus(_, let state) = event { return state }
            return nil
        }

        XCTAssertEqual(states.last, .idle)
        XCTAssertFalse(
            states.contains { $0.isFinished },
            "the input stream stays open, so a finished turn must not retire the session"
        )
    }

    /// The event the dial leans on: it moves the mode on the app's word and
    /// nothing puts a change back, so a session that never took one has only
    /// this to say so with.
    func testASessionReportsTheModeItIsActuallyIn() throws {
        let line = Data(#"{"type":"session.mode","key":"k","permissionMode":"plan"}"#.utf8)
        let event = try JSONDecoder().decode(HostEvent.self, from: line)
        XCTAssertEqual(event, .sessionMode(key: "k", permissionMode: "plan"))
        XCTAssertEqual(event.sessionKey, "k")
    }

    /// The pair the whole feature rests on. `taskId` is what stops the agent and
    /// `toolUseId` is the only thing that says which row it belongs to — the
    /// transcript knows an agent by the call that spawned it and has never heard
    /// of a task id.
    func testATaskNamesBothTheWorkAndTheCallItCameFrom() throws {
        let line = Data(
            """
            {"type":"session.tasks","key":"k","tasks":[\
            {"taskId":"a6d2f0b4c81e93a71","toolUseId":"toolu_01Lq8","description":"count slowly"}]}
            """.utf8
        )
        let event = try JSONDecoder().decode(HostEvent.self, from: line)
        XCTAssertEqual(
            event,
            .sessionTasks(
                key: "k",
                tasks: [
                    HostTask(
                        taskId: "a6d2f0b4c81e93a71",
                        toolUseId: "toolu_01Lq8",
                        description: "count slowly"
                    )
                ]
            )
        )
        XCTAssertEqual(event.sessionKey, "k")
    }

    /// Nothing on a task says what raised it, so the host names the call's tool
    /// beside it — and a host from before the field says nothing, which has to
    /// read as work rather than as a watcher.
    func testATaskCarriesTheToolItCameFromWhenTheHostKnowsIt() throws {
        let line = Data(
            """
            {"type":"session.tasks","key":"k","tasks":[\
            {"taskId":"t1","toolUseId":"toolu_01Lq8","description":"watch the log","tool":"Monitor"},\
            {"taskId":"t2","toolUseId":"toolu_01Mr9","description":"count slowly"}]}
            """.utf8
        )
        guard case .sessionTasks(_, let tasks) = try JSONDecoder().decode(HostEvent.self, from: line)
        else { return XCTFail("a task set") }

        XCTAssertEqual(tasks.first?.tool, "Monitor")
        XCTAssertTrue(tasks.first?.isWatcher == true)
        XCTAssertNil(tasks.last?.tool)
        XCTAssertFalse(tasks.last?.isWatcher == true)
    }

    /// The set is how the app learns a task ended, so an empty one has to arrive
    /// as an event rather than as nothing.
    func testNothingRunningIsStillAnEvent() throws {
        let line = Data(#"{"type":"session.tasks","key":"k","tasks":[]}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(HostEvent.self, from: line),
            .sessionTasks(key: "k", tasks: [])
        )
    }

    /// A host from before streaming was taken out still sends it, and outlives
    /// the app that stopped reading it.
    func testAnOlderHostsWritingLevelIsReadPast() throws {
        let line = Data(#"{"type":"session.writing","key":"k","text":"Launching."}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(HostEvent.self, from: line), .unrecognised(type: "session.writing"))
    }

    func testARenameNamesTheTranscriptNotTheKey() throws {
        let line = try HostRequest.rename(id: "r3", sessionId: "0f6f", title: "Billing bug").line()

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "rename")
        XCTAssertEqual(json["sessionId"] as? String, "0f6f")
        XCTAssertEqual(json["title"] as? String, "Billing bug")
        XCTAssertNil(json["key"])
    }

    func testASideQuestionCarriesItsHistoryOnlyWhenThereIsOne() throws {
        let first = try HostRequest.side(id: "s1", key: "k", question: "why?", history: []).line()
        let firstJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(firstJSON["type"] as? String, "side")
        XCTAssertEqual(firstJSON["key"] as? String, "k")
        XCTAssertEqual(firstJSON["question"] as? String, "why?")
        XCTAssertNil(firstJSON["history"])

        let next = try HostRequest.side(
            id: "s2", key: "k", question: "and?",
            history: [SideExchange(question: "why?", response: "because")]
        ).line()
        let nextJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: next) as? [String: Any])
        let history = try XCTUnwrap(nextJSON["history"] as? [[String: String]])
        XCTAssertEqual(history, [["question": "why?", "response": "because"]])
    }

    func testASideReplyCarriesTheAnswer() throws {
        let data = Data(#"{"type":"reply","id":"s1","ok":true,"response":"because"}"#.utf8)
        guard case .reply(let reply) = try JSONDecoder().decode(HostEvent.self, from: data) else {
            return XCTFail("not a reply")
        }
        XCTAssertEqual(reply.response, "because")
    }

    func testTheMcpRequestsNameTheServer() throws {
        for (request, type) in [
            (HostRequest.mcpReconnect(id: "r1", key: "k1", server: "claude.ai Linear"), "mcpReconnect"),
            (HostRequest.mcpLogin(id: "r1", key: "k1", server: "claude.ai Linear"), "mcpLogin"),
        ] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.line()) as? [String: Any])
            XCTAssertEqual(json["type"] as? String, type)
            XCTAssertEqual(json["key"] as? String, "k1")
            XCTAssertEqual(json["server"] as? String, "claude.ai Linear")
        }
    }

    /// Stopping one agent and stopping the turn are different requests, and the
    /// turn's takes every agent it was waiting on with it.
    func testStoppingOneAgentNamesTheTask() throws {
        let line = try HostRequest.stopTask(id: "r9", key: "k1", taskId: "a85ae").line()

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "stopTask")
        XCTAssertEqual(json["key"] as? String, "k1")
        XCTAssertEqual(json["taskId"] as? String, "a85ae")
        XCTAssertEqual(json["id"] as? String, "r9")
        XCTAssertEqual(line.last, 0x0A)
    }

    /// A session reports itself from the moment `start` answers, which is
    /// before its first `init`. Empty there would be a positive claim that it
    /// runs nothing, and the menu would grey every row of a session that had
    /// simply not been asked yet.
    func testASessionThatHasNotBeenNamedYetSaysNullRatherThanNothing() throws {
        let line = Data(#"{"type":"session.init","key":"k","sessionId":"s","cwd":"/tmp","model":null,"permissionMode":"default","tools":[],"commands":null}"#.utf8)
        let event = try JSONDecoder().decode(HostEvent.self, from: line)

        guard case .sessionInit(let start) = event else { return XCTFail("not an init") }
        XCTAssertNil(start.commands)
    }

    /// What the session is thinking at, on the message that says it started.
    /// An app already connected hears the level nowhere else until the dial
    /// moves it — the summary that carries one rides on the welcome.
    func testAnInitNamesTheLevelTheSessionRunsAt() throws {
        let line = Data(
            #"{"type":"session.init","key":"k","sessionId":"s","cwd":"/tmp","model":null,"permissionMode":"default","effort":"low","tools":[],"commands":null}"#
                .utf8)
        let event = try JSONDecoder().decode(HostEvent.self, from: line)

        guard case .sessionInit(let start) = event else { return XCTFail("not an init") }
        XCTAssertEqual(start.effort, "low")
    }

    /// A host from before the field sends none, and the event still has to
    /// decode: the app would otherwise go deaf to every session that started.
    func testAnInitFromAHostTooOldToNameALevelStillDecodes() throws {
        let line = Data(
            #"{"type":"session.init","key":"k","sessionId":"s","cwd":"/tmp","model":null,"permissionMode":"default","tools":[],"commands":null}"#
                .utf8)
        let event = try JSONDecoder().decode(HostEvent.self, from: line)

        guard case .sessionInit(let start) = event else { return XCTFail("not an init") }
        XCTAssertNil(start.effort)
    }

    /// An app already connected when a watcher starts a session never gets
    /// that session's summary, so the init is its only word on the name and
    /// the origin.
    func testAnInitCarriesTheStartsNameAndOriginToTheIndex() throws {
        let line = Data(
            #"{"type":"session.init","key":"k","sessionId":"s","cwd":"/tmp","name":"CI fail: feature/foo","origin":{"watcher":"ci-watch","reason":"tests failed on PR #12"},"model":null,"permissionMode":"default","tools":[],"commands":null}"#
                .utf8)
        var index = HostSessionIndex()
        index.apply(try JSONDecoder().decode(HostEvent.self, from: line))

        XCTAssertEqual(index.sessions["k"]?.name, "CI fail: feature/foo")
        XCTAssertEqual(index.sessions["k"]?.origin, SessionOrigin(watcher: "ci-watch", reason: "tests failed on PR #12"))
    }

    /// Named the way `start` names it, for the reason the mode is: the host
    /// checks an `effort` request against its own list and lets a `start` past
    /// unchecked, so a level that launches under one name and moves under
    /// another is refused mid-session.
    func testAnEffortChangeNamesTheLevelTheWayAStartDoes() throws {
        let changed = try HostRequest.effort(id: "r10", key: "k1", effort: "xhigh").line()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: changed) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "effort")
        XCTAssertEqual(json["id"] as? String, "r10")
        XCTAssertEqual(json["key"] as? String, "k1")
        XCTAssertEqual(json["effort"] as? String, "xhigh")
        XCTAssertEqual(changed.last, 0x0A)

        let started = try HostRequest.start(
            id: "r11", cwd: "/tmp", prompt: "hi", effort: EffortLevel.named("xhigh").hostEffortID
        ).line()
        let launch = try XCTUnwrap(JSONSerialization.jsonObject(with: started) as? [String: Any])
        XCTAssertEqual(launch["effort"] as? String, json["effort"] as? String)
    }

    /// The style goes out with the launch or not at all. There is deliberately
    /// no request to move one, and since CLI v2.1.278 that is the app's choice
    /// rather than the SDK's limit: `applyFlagSettings` now moves a running
    /// session's style from the next turn, and `/output-style` now answers
    /// rather than refusing. The app keeps one app-wide pick bound at launch, so
    /// this wire stays as it is.
    func testTheOutputStyleRidesOnTheStartAndHasNoRequestOfItsOwn() throws {
        let line = try HostRequest.start(
            id: "r12", cwd: "/tmp", prompt: "hi", outputStyle: "ELI5"
        ).line()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(json["outputStyle"] as? String, "ELI5")

        // Left unsent rather than sent empty: the settings files decide, and a
        // blank name is a style that matches no file on disk.
        let inherited = try HostRequest.start(
            id: "r13", cwd: "/tmp", prompt: "hi", outputStyle: OutputStyle.inherited.hostStyleID
        ).line()
        let bare = try XCTUnwrap(JSONSerialization.jsonObject(with: inherited) as? [String: Any])
        XCTAssertNil(bare["outputStyle"])
    }

    /// Read out of a real capture rather than a hand-written line. Both are
    /// events the app added itself, and an event the host stopped sending would
    /// pass every encoding test above while never reaching the app again.
    func testARealSessionCarriesTheStyleAndTheEffort() throws {
        let events = try wire()

        let opening = try XCTUnwrap(
            events.compactMap { event -> HostSessionInit? in
                if case .sessionInit(let start) = event { return start }
                return nil
            }.first
        )
        // The CLI's own word for what it resolved, which is what makes it worth
        // carrying: the smoke run asks for a style its `settingSources: []`
        // leaves it unable to find any file for.
        XCTAssertNotNil(opening.outputStyle)

        let effort = events.compactMap { event -> String? in
            if case .sessionEffort(_, let effort) = event { return effort }
            return nil
        }
        XCTAssertEqual(effort, ["high"])

        let styles = try XCTUnwrap(
            events.compactMap { event -> [String]? in
                if case .outputStyles(let styles) = event { return styles }
                return nil
            }.first
        )
        XCTAssertFalse(styles.isEmpty)
    }

    /// What the pickers' Default row is named after, out of a real capture. A
    /// row that says only "Default" is the app declining to say what it will
    /// do, which is what the model picker has never done.
    func testARealSessionCarriesWhatDefaultResolvesTo() throws {
        let resolved = try XCTUnwrap(
            try wire().compactMap { event -> HostDefaults? in
                if case .defaults(let defaults) = event { return defaults }
                return nil
            }.first
        )

        XCTAssertFalse(resolved.cwd.isEmpty, "the answer names the folder it is about")
        // Not asserted to a particular value: it is whatever this machine's
        // settings cascade says, and pinning one would pin the tester's config.
        // What matters is that both keys decode — a rename on either is a
        // Default row that quietly goes back to the bare word.
        XCTAssertTrue(resolved.outputStyle != nil || resolved.effort != nil)
    }

    /// The capture's later defaults are for folders whose settings pin a
    /// model — one by the model key, one through env — and the smoke writes
    /// both pins, so these are value-asserted: a rename anywhere on the path
    /// is a model chip that quietly goes absent for Default launches.
    func testARealFolderModelPinRidesTheWire() throws {
        let answers = try wire().compactMap { event -> HostDefaults.Model? in
            if case .defaults(let defaults) = event { return defaults.model }
            return nil
        }
        XCTAssertEqual(answers, [.unnamed, .named("sonnet"), .named("claude-opus-4-1")])
    }

    /// Asked by folder, because the pickers are open before any session exists
    /// and a project can carry settings of its own.
    func testDefaultsAreAskedForByFolder() throws {
        let line = try HostRequest.resolveDefaults(id: "r14", cwd: "/tmp/work").line()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "defaults")
        XCTAssertEqual(json["id"] as? String, "r14")
        XCTAssertEqual(json["cwd"] as? String, "/tmp/work")
        XCTAssertNil(json["key"], "it names no session — there may not be one")
    }

    /// Null is not absent and not a level: it is nothing in the cascade setting
    /// it, and the picker saying Default and stopping rather than naming a value
    /// no file asked for.
    func testAFolderThatSetsNothingDecodesAsNothing() throws {
        let line = Data(
            #"{"type":"host.defaults","cwd":"/tmp","outputStyle":null,"effort":null,"model":null}"#
                .utf8)
        let event = try JSONDecoder().decode(HostEvent.self, from: line)

        guard case .defaults(let resolved) = event else { return XCTFail("not a defaults") }
        XCTAssertNil(resolved.outputStyle)
        XCTAssertNil(resolved.effort)
        XCTAssertEqual(resolved.model, .unnamed)
        XCTAssertEqual(resolved.cwd, "/tmp")
    }

    /// Null and absent are different answers here, unlike everywhere else on
    /// this event: null is the resolver saying no file names one, absence is a
    /// host that never answered — an older build, or an SDK without the
    /// resolver. The chip asserts a name on the first and must stay quiet on
    /// the second, because the folder may pin a model the old host cannot see.
    func testAFolderModelPinDecodesAndAnOldHostReadsAsUnanswered() throws {
        let pinned = Data(
            #"{"type":"host.defaults","cwd":"/tmp","outputStyle":null,"effort":null,"model":"sonnet"}"#
                .utf8)
        guard case .defaults(let resolved) = try JSONDecoder().decode(HostEvent.self, from: pinned)
        else { return XCTFail("not a defaults") }
        XCTAssertEqual(resolved.model, .named("sonnet"))

        let old = Data(#"{"type":"host.defaults","cwd":"/tmp","outputStyle":"ELI5","effort":null}"#.utf8)
        guard case .defaults(let elder) = try JSONDecoder().decode(HostEvent.self, from: old)
        else { return XCTFail("not a defaults") }
        XCTAssertEqual(elder.model, .unanswered)
    }

    // MARK: - Reading past what we don't know

    func testAnEventFromANewerHostIsReadPastRatherThanFatal() throws {
        let line = Data(#"{"type":"session.vibe","key":"k","vibe":"good"}"#.utf8)
        let event = try JSONDecoder().decode(HostEvent.self, from: line)
        XCTAssertEqual(event, .unrecognised(type: "session.vibe"))
    }

    func testAStateFromANewerHostKeepsItsName() throws {
        let line = Data(#"{"type":"session.status","key":"k","state":"hibernating"}"#.utf8)
        let event = try JSONDecoder().decode(HostEvent.self, from: line)
        XCTAssertEqual(event, .sessionStatus(key: "k", state: .unknown("hibernating")))
    }

    /// The stretch where the CLI is summarising the conversation. It writes
    /// nothing and answers nothing, so the host's word is the only one there is.
    func testCompactingIsAStateTheHostCanName() throws {
        let line = Data(#"{"type":"session.status","key":"k","state":"compacting"}"#.utf8)
        let event = try JSONDecoder().decode(HostEvent.self, from: line)
        XCTAssertEqual(event, .sessionStatus(key: "k", state: .compacting))
        XCTAssertEqual(HostSessionState(raw: "compacting").raw, "compacting")
    }

    /// The host writes `error`; the app says `failed`, since `error` reads as a
    /// thing gone wrong rather than a state a session rests in.
    func testTheErrorStateRoundTripsUnderItsWireName() {
        XCTAssertEqual(HostSessionState(raw: "error"), .failed)
        XCTAssertEqual(HostSessionState.failed.raw, "error")
    }

    // MARK: - Requests

    func testHelloStatesTheProtocolItSpeaks() throws {
        let line = try HostRequest.hello(id: "r1").line()
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "hello")
        XCTAssertEqual(json["protocol"] as? Int, HostProtocol.version)
        XCTAssertEqual(line.last, 0x0A, "the host reads requests a line at a time")
        XCTAssertNil(json["launches"], "a client takes launches only when it says so")
    }

    func testOnlyALocalAppOffersToTakeLaunches() throws {
        let line = try HostRequest.hello(id: "r1", launches: true).line()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(json["launches"] as? Bool, true)
    }

    func testALaunchDecodesWithTheSessionThatAskedForIt() throws {
        let line = Data(#"{"type":"launch","launchId":"l1","cwd":"/p","prompt":"go","name":"Child","parent":"k0"}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(HostEvent.self, from: line),
            .launch(HostLaunch(launchId: "l1", cwd: "/p", prompt: "go", name: "Child", parent: "k0"))
        )
    }

    func testALaunchIsAnsweredWithTheKeyOrTheReason() throws {
        let started = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: HostRequest.launched(id: "r2", launchId: "l1", key: "k1").line()
            ) as? [String: Any]
        )
        XCTAssertEqual(started["type"] as? String, "launched")
        XCTAssertEqual(started["launchId"] as? String, "l1")
        XCTAssertEqual(started["key"] as? String, "k1")
        XCTAssertNil(started["error"])

        let refused = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: HostRequest.launched(id: "r3", launchId: "l1", error: "no host").line()
            ) as? [String: Any]
        )
        XCTAssertEqual(refused["error"] as? String, "no host")
        XCTAssertNil(refused["key"])
    }

    func testAStartedChildCarriesItsParentAsOrigin() throws {
        let line = try HostRequest.start(
            id: "r4", cwd: "/tmp", prompt: "hi", origin: SessionOrigin(parent: "k0")
        ).line()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(json["origin"] as? [String: String], ["parent": "k0"])
    }

    func testAnAnsweredQuestionCarriesTheLabelsUnderTheQuestionText() throws {
        let line = try HostRequest.answerQuestion(
            id: "r2",
            askId: "a1",
            answers: [
                "How should I format the output?": .one("Summary"),
                "Which sections?": .many(["Introduction", "Conclusion"]),
            ]
        ).line()

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        let answers = try XCTUnwrap(json["answers"] as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "question")
        XCTAssertEqual(answers["How should I format the output?"] as? String, "Summary")
        XCTAssertEqual(
            answers["Which sections?"] as? [String],
            ["Introduction", "Conclusion"]
        )
    }

    /// The SDK reads notes out of `annotations[question].notes`, so a flat
    /// question-to-string map would be dropped on the way through.
    func testNotesArriveUnderTheQuestionTheyWereWrittenBeside() throws {
        let line = try HostRequest.answerQuestion(
            id: "r2",
            askId: "a1",
            answers: ["Which accent colour?": .one("Red")],
            notes: ["Which accent colour?": "and keep it under 40kb"]
        ).line()

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        let annotations = try XCTUnwrap(json["annotations"] as? [String: Any])
        let written = try XCTUnwrap(annotations["Which accent colour?"] as? [String: Any])
        XCTAssertEqual(written["notes"] as? String, "and keep it under 40kb")
    }

    func testAQuestionAnsweredWithoutNotesSendsNoAnnotations() throws {
        let line = try HostRequest.answerQuestion(
            id: "r2", askId: "a1", answers: ["Which accent colour?": .one("Red")]
        ).line()

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertNil(json["annotations"], "an empty map is not something to send")
    }

    /// Free text is an answer like any other: the CLI echoes what is under the
    /// question without checking it against the labels it offered.
    func testAnAnswerNeedNotBeOneOfTheOfferedLabels() throws {
        let line = try HostRequest.answerQuestion(
            id: "r2",
            askId: "a1",
            answers: ["Which accent colour?": .one("Neither — a chartreuse gradient")]
        ).line()

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        let answers = try XCTUnwrap(json["answers"] as? [String: Any])
        XCTAssertEqual(
            answers["Which accent colour?"] as? String,
            "Neither — a chartreuse gradient"
        )
    }

    /// Said instead of answering, which is the whole of what the CLI records —
    /// so nothing is sent beside it that the result would silently drop.
    func testARespondedQuestionCarriesTheTextAndNoAnswers() throws {
        let line = try HostRequest.answerQuestion(
            id: "r2", askId: "a1", answers: [:], response: "Neither, let's talk about it"
        ).line()

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(json["response"] as? String, "Neither, let's talk about it")
        XCTAssertEqual((json["answers"] as? [String: Any])?.isEmpty, true)
    }

    func testAnAnsweredPermissionNamesTheOptionRatherThanABoolean() throws {
        let line = try HostRequest.answerPermission(
            id: "r3", askId: "a2", optionId: "allow_always"
        ).line()

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "permission")
        XCTAssertEqual(json["optionId"] as? String, "allow_always")
        XCTAssertNil(json["allow"], "allow/remember booleans were replaced by the option list")
    }

    /// What was typed instead of pressing Deny. The sidecar sends it on as the
    /// denial's message, and it is the whole of what the model gets in place of
    /// the result — so a refusal that dropped it would read as a bare no.
    func testARefusalCarriesTheReasonItWasRefusedFor() throws {
        let line = try HostRequest.answerPermission(
            id: "r5", askId: "a3", optionId: "reject_once", message: "not that path"
        ).line()

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(json["optionId"] as? String, "reject_once")
        XCTAssertEqual(json["message"] as? String, "not that path")
    }

    /// The buttons are the host's own, named for tool calls in general. Neither
    /// name is what agreeing to a plan is called.
    func testAPlansOptionsAreNamedForWhatTheyDecide() {
        XCTAssertEqual(HostAskOptionKind.allowOnce.planName, "Approve")
        XCTAssertEqual(HostAskOptionKind.rejectOnce.planName, "Keep planning")
        XCTAssertNil(HostAskOptionKind.unknown("something_else").planName)
    }

    func testAbsentOptionalsAreLeftOffRatherThanSentAsNull() throws {
        let line = try HostRequest.start(id: "r4", cwd: "/tmp", prompt: "hi").line()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertNil(json["model"])
        XCTAssertNil(json["permissionMode"])
        XCTAssertNil(json["name"])
        XCTAssertNil(json["resume"], "a start with no resume is a new conversation")
        XCTAssertNil(json["key"], "and one with no key is the host's to name")
    }

    func testAStartCarriesAnAPIKeyOnlyWhenGivenOne() throws {
        let plain = try HostRequest.start(id: "r4", cwd: "/tmp", prompt: "hi").line()
        let keyed = try HostRequest.start(id: "r5", cwd: "/tmp", prompt: "hi", apiKey: "sk-test").line()
        XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])["apiKey"])
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: keyed) as? [String: Any])["apiKey"] as? String, "sk-test")
    }

    /// The two halves of picking a conversation up: which transcript to continue,
    /// and which row it comes back as.
    func testAResumeNamesBothTheTranscriptAndTheRowItComesBackAs() throws {
        let line = try HostRequest.start(
            id: "r6", cwd: "/tmp", prompt: "where were we?",
            resume: "uuid-1", key: "k1"
        ).line()

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "start")
        XCTAssertEqual(json["resume"] as? String, "uuid-1")
        XCTAssertEqual(json["key"] as? String, "k1")
        XCTAssertEqual(json["prompt"] as? String, "where were we?")
    }

    /// An interrupt names the session and nothing else — there is only one turn
    /// to end, and which one is the host's to know.
    func testAnInterruptNamesOnlyTheSession() throws {
        let line = try HostRequest.interrupt(id: "r7", key: "k1").line()

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "interrupt")
        XCTAssertEqual(json["key"] as? String, "k1")
        XCTAssertEqual(json["id"] as? String, "r7")
        XCTAssertEqual(line.last, 0x0A)
    }

    /// The pane's stop button ends the turn; the host reads `stop` as ending the
    /// session and forgetting it. Sending the wrong one closes a conversation
    /// somebody meant to carry on.
    func testInterruptIsNotStop() throws {
        let interrupt = try HostRequest.interrupt(id: "r7", key: "k1").line()
        let stop = try HostRequest.stop(id: "r7", key: "k1").line()

        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: interrupt) as? [String: Any])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: stop) as? [String: Any])
        XCTAssertEqual(first["type"] as? String, "interrupt")
        XCTAssertEqual(second["type"] as? String, "stop")
    }

    /// Named the same way `start` names it. The host checks a `mode` request
    /// against its own list and lets a `start` past unchecked, so a mode that
    /// dispatches under one name and moves under another is refused mid-session.
    func testAModeChangeNamesTheModeTheWayAStartDoes() throws {
        let changed = try HostRequest.mode(id: "r7", key: "k1", permissionMode: "auto").line()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: changed) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "mode")
        XCTAssertEqual(json["id"] as? String, "r7")
        XCTAssertEqual(json["key"] as? String, "k1")
        XCTAssertEqual(json["permissionMode"] as? String, "auto")

        let started = try HostRequest.start(
            id: "r8", cwd: "/tmp", prompt: "hi", permissionMode: "auto"
        ).line()
        let launch = try XCTUnwrap(JSONSerialization.jsonObject(with: started) as? [String: Any])
        XCTAssertEqual(launch["permissionMode"] as? String, json["permissionMode"] as? String)
    }

    func testAWelcomeNamesItsConfigDirectory() throws {
        let welcomes = try wire().compactMap { event -> HostWelcome? in
            if case .welcome(let welcome) = event { return welcome }
            return nil
        }

        let old = try XCTUnwrap(welcomes.first)
        XCTAssertEqual(old.capabilities, [])
        XCTAssertNil(old.configDir)

        let current = try XCTUnwrap(welcomes.last)
        XCTAssertEqual(current.configDir, "/Users/me/.claude")
    }

}
