import XCTest
@testable import DexCore

final class SlashCompletionTests: XCTestCase {

    private let catalogue = [
        Command(name: "clear", summary: "Start a new session with empty context"),
        Command(name: "code-review", summary: "Review the current diff"),
        Command(name: "compact", summary: "Free up context by summarizing"),
        Command(name: "config", summary: "Open settings"),
        Command(name: "review", summary: "Review a GitHub pull request"),
        Command(name: "ship-it", summary: "Merge and push", isCustom: true),
    ]

    private func names(_ draft: String, limit: Int = 8) -> [String] {
        SlashCompletion.matches(for: draft, in: catalogue, limit: limit).map(\.name)
    }

    // When the menu is worth offering

    func testASlashOnItsOwnOffersEverything() {
        XCTAssertEqual(names("/").count, 6)
    }

    func testProseIsNotACommand() {
        XCTAssertNil(SlashCompletion.query(in: "have a look at src/main.swift"))
        XCTAssertEqual(names("have a look"), [])
    }

    /// A slash starts a command only at the start of a message. Past the first
    /// space you are writing the command's argument, or a path, or a date.
    func testTheMenuClosesOnceTheNameIsDone() {
        XCTAssertNil(SlashCompletion.query(in: "/review 402"))
        XCTAssertEqual(names("/review 402"), [])
    }

    func testASlashInsideAPathIsNotACommand() {
        XCTAssertNil(SlashCompletion.query(in: "read Sources/App/main.swift"))
    }

    func testTheQueryIsWhatFollowsTheSlash() {
        XCTAssertEqual(SlashCompletion.query(in: "/comp"), "comp")
        XCTAssertEqual(SlashCompletion.query(in: "/"), "")
    }

    // What it offers

    func testWhatYouTypedIsMatchedFromTheStartOfAName() {
        XCTAssertEqual(names("/comp"), ["compact"])
    }

    /// "review" is in the middle of "code-review" and the whole of "review".
    /// The one you spelled out comes first.
    func testANameThatStartsWithTheQueryBeatsOneThatMerelyContainsIt() {
        XCTAssertEqual(names("/review").first, "review")
        XCTAssertTrue(names("/review").contains("code-review"))
    }

    func testMatchingIgnoresCase() {
        XCTAssertEqual(names("/CLEAR"), ["clear"])
    }

    func testLettersScatteredThroughANameStillFindIt() {
        XCTAssertTrue(names("/cdrv").contains("code-review"))
    }

    func testNothingMatchesNothing() {
        XCTAssertEqual(names("/zzzz"), [])
    }

    func testTheListIsCappedSoItDoesNotCoverTheReading() {
        XCTAssertEqual(names("/", limit: 3).count, 3)
    }

    // Taking one

    func testTakingACommandLeavesRoomForWhatItTakes() {
        let command = Command(name: "review", summary: "")

        XCTAssertEqual(SlashCompletion.accepting(command, in: "/rev"), "/review ")
    }

    func testTakingACommandKeepsTheMessageAfterTheCaret() {
        let command = Command(name: "btw", summary: "")

        XCTAssertEqual(SlashCompletion.accepting(command, in: "/b is this right?", caret: "/b"),
                       "/btw is this right?")
    }

    func testTakingACommandDoesNotDisturbProse() {
        let command = Command(name: "review", summary: "")

        XCTAssertEqual(SlashCompletion.accepting(command, in: "look at this"), "look at this")
    }
}

final class SlashCommandsTests: XCTestCase {

    private func merged(custom: [String: [CommandFile]]) -> [Command] {
        SlashCommands.all(
            forProject: "/p/alpha",
            configDirectory: "/home/me/.claude",
            reading: { custom[$0] ?? [] },
            readingSkills: { custom[$0] ?? [] }
        )
    }

    func testTheCLIsOwnCommandsAreOffered() {
        let all = merged(custom: [:])

        XCTAssertTrue(all.contains { $0.name == "clear" })
        XCTAssertTrue(all.contains { $0.name == "compact" })
        XCTAssertFalse(all.contains { $0.isCustom })
    }

    func testAUsersOwnCommandsAreOfferedToo() {
        let all = merged(custom: [
            "/home/me/.claude/commands": [CommandFile(name: "ship", summary: "Merge and push")],
        ])

        let ship = all.first { $0.name == "ship" }
        XCTAssertEqual(ship?.summary, "Merge and push")
        XCTAssertEqual(ship?.isCustom, true)
    }

    /// Both would be offered, but only one would run.
    func testAProjectsCommandWinsOverTheUsersOfTheSameName() {
        let all = merged(custom: [
            "/home/me/.claude/commands": [CommandFile(name: "ship", summary: "the user's")],
            "/p/alpha/.claude/commands": [CommandFile(name: "ship", summary: "the project's")],
        ])

        XCTAssertEqual(all.filter { $0.name == "ship" }.count, 1)
        XCTAssertEqual(all.first { $0.name == "ship" }?.summary, "the project's")
    }

    func testACommandWrittenOverACLIOneReplacesIt() {
        let all = merged(custom: [
            "/p/alpha/.claude/commands": [CommandFile(name: "review", summary: "ours")],
        ])

        XCTAssertEqual(all.filter { $0.name == "review" }.count, 1)
        XCTAssertEqual(all.first { $0.name == "review" }?.isCustom, true)
    }

    func testWithNoProjectOnlyTheUsersOwnAreRead() {
        XCTAssertEqual(SlashCommands.scopes(forProject: nil, configDirectory: "/home/me/.claude"),
                       ["/home/me/.claude"])
        XCTAssertEqual(SlashCommands.scopes(forProject: "", configDirectory: "/home/me/.claude"),
                       ["/home/me/.claude"])
    }

    private func seeded() throws -> (home: URL, config: URL, project: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("slash-config-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let config = root.appendingPathComponent("config")
        let project = root.appendingPathComponent("project")
        for (dir, tag) in [(home.appendingPathComponent(".claude"), "home"),
                           (config, "config"),
                           (project.appendingPathComponent(".claude"), "project")] {
            let skill = dir.appendingPathComponent("skills/\(tag)skill")
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("commands"), withIntermediateDirectories: true)
            try "\(tag) command".write(
                to: dir.appendingPathComponent("commands/\(tag)cmd.md"), atomically: true, encoding: .utf8)
            try "\(tag) skill".write(
                to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        return (home, config, project)
    }

    private func customNames(settingConfigDir: Bool) throws -> Set<String> {
        let (home, config, project) = try seeded()
        let environment = settingConfigDir ? ["CLAUDE_CONFIG_DIR": config.path] : [:]
        let directory = ConfigDirectory.resolve(environment: environment, home: home)
        return Set(SlashCommands.all(forProject: project.path, configDirectory: directory.path)
            .filter(\.isCustom).map(\.name))
    }

    func testWithoutAConfigDirTheUsersComeFromHome() throws {
        XCTAssertEqual(try customNames(settingConfigDir: false),
                       ["homecmd", "homeskill", "projectcmd", "projectskill"])
    }

    /// `Scripts/config-dir-commands-probe.py`: the CLI stops reading `~/.claude` once it is set.
    func testWithAConfigDirTheUsersComeFromThereAlone() throws {
        XCTAssertEqual(try customNames(settingConfigDir: true),
                       ["configcmd", "configskill", "projectcmd", "projectskill"])
    }

    func testASkillIsOfferedLikeACommand() {
        let all = merged(custom: [
            "/home/me/.claude/skills": [CommandFile(name: "land", summary: "Merge and push")],
        ])

        let land = all.first { $0.name == "land" }
        XCTAssertEqual(land?.summary, "Merge and push")
        XCTAssertEqual(land?.isCustom, true)
    }

    /// The CLI reads both directories, so the same name in each is one command.
    func testASkillAndACommandOfTheSameNameAreOfferedOnce() {
        let all = merged(custom: [
            "/home/me/.claude/commands": [CommandFile(name: "land", summary: "the command")],
            "/home/me/.claude/skills": [CommandFile(name: "land", summary: "the skill")],
        ])

        XCTAssertEqual(all.filter { $0.name == "land" }.count, 1)
    }

    func testAProjectSkillWinsOverTheUsers() {
        let all = merged(custom: [
            "/home/me/.claude/skills": [CommandFile(name: "land", summary: "the user's")],
            "/p/alpha/.claude/skills": [CommandFile(name: "land", summary: "the project's")],
        ])

        XCTAssertEqual(all.first { $0.name == "land" }?.summary, "the project's")
    }
}

final class CommandFileTests: XCTestCase {

    func testTheDescriptionInTheFrontmatterIsTheSummary() {
        let summary = CommandFile.summary(of: """
        ---
        description: Merge the worktree back into main
        allowed-tools: Bash
        ---

        Do the merge.
        """)

        XCTAssertEqual(summary, "Merge the worktree back into main")
    }

    func testAQuotedDescriptionLosesItsQuotes() {
        XCTAssertEqual(
            CommandFile.summary(of: "---\ndescription: \"Ship it\"\n---\n"),
            "Ship it"
        )
    }

    func testWithoutFrontmatterTheFirstLineOfProseStandsIn() {
        let summary = CommandFile.summary(of: """
        # Ship

        Merge and push the branch.
        """)

        XCTAssertEqual(summary, "Merge and push the branch.")
    }

    func testAFileWithNothingToSayGetsNoSummary() {
        XCTAssertEqual(CommandFile.summary(of: ""), "")
        XCTAssertEqual(CommandFile.summary(of: "\n\n# Only a heading\n"), "")
    }

    /// The CLI addresses a command in a folder through it, and so does the menu.
    func testACommandInAFolderIsAddressedThroughIt() {
        let base = URL(fileURLWithPath: "/home/me/.claude/commands", isDirectory: true)
        let file = URL(fileURLWithPath: "/home/me/.claude/commands/review/api.md")

        XCTAssertEqual(CommandFile.name(of: file, under: base), "review:api")
    }

    func testACommandAtTheTopIsJustItsName() {
        let base = URL(fileURLWithPath: "/home/me/.claude/commands", isDirectory: true)
        let file = URL(fileURLWithPath: "/home/me/.claude/commands/ship.md")

        XCTAssertEqual(CommandFile.name(of: file, under: base), "ship")
    }

    /// A personal skill is addressed by its folder; the frontmatter `name` is
    /// only the label the CLI shows in listings.
    func testASkillIsAddressedByItsFolderNotItsFrontmatter() {
        let base = URL(fileURLWithPath: "/home/me/.claude/skills", isDirectory: true)
        let file = URL(fileURLWithPath: "/home/me/.claude/skills/ship/SKILL.md")

        XCTAssertEqual(CommandFile.skillName(of: file, under: base), "ship")
    }

    func testASkillSaysWhenItIsNotForTyping() {
        XCTAssertTrue(CommandFile.hidesItself("---\nuser-invocable: false\n---\n"))
        XCTAssertFalse(CommandFile.hidesItself("---\nuser-invocable: true\n---\n"))
        XCTAssertFalse(CommandFile.hidesItself("---\ndescription: Land it\n---\n"))
        XCTAssertFalse(CommandFile.hidesItself("# Land\n"))
    }

    func testADescriptionlessFileDoesNotFallBackToItsFrontmatter() {
        let summary = CommandFile.summary(of: """
        ---
        name: land
        allowed-tools: Bash
        ---

        Merge the worktree back into main.
        """)

        XCTAssertEqual(summary, "Merge the worktree back into main.")
    }
}

final class SkillDirectoryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("skills-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ contents: String, to relativePath: String) throws {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func testReadsASkillFromItsFolder() throws {
        try write("---\ndescription: Merge and push\n---\n", to: "land/SKILL.md")

        XCTAssertEqual(
            CommandFile.readSkills(root: root.path),
            [CommandFile(name: "land", summary: "Merge and push")]
        )
    }

    func testLeavesOutSkillsThatAreNotForTyping() throws {
        try write("---\ndescription: Background\nuser-invocable: false\n---\n", to: "ctx/SKILL.md")
        try write("---\ndescription: Merge and push\n---\n", to: "land/SKILL.md")

        XCTAssertEqual(CommandFile.readSkills(root: root.path).map(\.name), ["land"])
    }

    func testIgnoresTheSupportingFilesBesideASkill() throws {
        try write("---\ndescription: Merge and push\n---\n", to: "land/SKILL.md")
        try write("# notes\n", to: "land/reference.md")

        XCTAssertEqual(CommandFile.readSkills(root: root.path).map(\.name), ["land"])
    }

    func testAMissingDirectoryIsNoSkills() {
        XCTAssertEqual(CommandFile.readSkills(root: root.path), [])
    }
}
