import XCTest
@testable import DexCore

private let app = AppCheckout.Layout.bundleName

private struct FakeFiles: FileProbe {
    let files: Set<String>
    init(_ files: [String]) { self.files = Set(files) }
    func isFile(_ path: String) -> Bool { files.contains(path) }
}

final class AppCheckoutTests: XCTestCase {
    private let root = "/Users/me/Projects/copper-agents-worker"
    private var bundle: String { root + "/.build/\(app)" }

    private func files(_ extra: [String] = []) -> FakeFiles {
        FakeFiles([root + "/Package.swift", root + "/Scripts/make-app.sh"] + extra)
    }

    func testTheCheckoutIsTheBundlesGrandparent() {
        let checkout = AppCheckout.resolve(bundlePath: bundle, files: files())
        XCTAssertEqual(checkout?.root, root)
        XCTAssertEqual(checkout?.bundlePath, bundle)
        XCTAssertEqual(checkout?.scriptPath, root + "/Scripts/make-app.sh")
    }

    func testAWorktreeResolvesToItselfAndIsNamedAfterItself() {

        let worktree = root + "/.claude/worktrees/working-spinner"
        let checkout = AppCheckout.resolve(
            bundlePath: worktree + "/.build/\(app)",
            files: FakeFiles([
                worktree + "/Package.swift",
                worktree + "/Scripts/make-app.sh",
                worktree + "/.git",
            ])
        )
        XCTAssertEqual(checkout?.root, worktree)
        XCTAssertEqual(checkout?.name, "working-spinner")
        XCTAssertEqual(checkout?.isWorktree, true, "a worktree's .git is a file pointing at the real one")
    }

    /// The whole point of the flag: the everyday copy says nothing
    /// about itself, so a named one in the menu bar is somebody's branch.
    func testTheCheckoutTheRepoLivesInIsNotAWorktree() {

        XCTAssertEqual(AppCheckout.resolve(bundlePath: bundle, files: files())?.isWorktree, false)
    }

    func testACopyOutsideAnyCheckoutResolvesToNothing() {

        XCTAssertNil(AppCheckout.resolve(bundlePath: "/Applications/\(app)", files: files()))
    }

    func testTheParentMustBeTheBuildDirectory() {
        XCTAssertNil(AppCheckout.resolve(
            bundlePath: root + "/dist/\(app)",
            files: files([root + "/Package.swift", root + "/Scripts/make-app.sh"])
        ))
    }

    func testSomeOtherAppInABuildDirectoryIsNotUs() {
        XCTAssertNil(AppCheckout.resolve(bundlePath: root + "/.build/Sketch.app", files: files()))
    }

    func testAMissingManifestResolvesToNothing() {

        XCTAssertNil(AppCheckout.resolve(
            bundlePath: bundle,
            files: FakeFiles([root + "/Scripts/make-app.sh"])
        ))
    }

    func testAMissingScriptResolvesToNothing() {
        XCTAssertNil(AppCheckout.resolve(
            bundlePath: bundle,
            files: FakeFiles([root + "/Package.swift"])
        ))
    }

    func testTheFilesystemRootIsNeverACheckout() {
        XCTAssertNil(AppCheckout.resolve(
            bundlePath: "/.build/\(app)",
            files: FakeFiles(["/Package.swift", "/Scripts/make-app.sh"])
        ))
    }

    func testATrailingSlashStillResolves() {
        XCTAssertEqual(AppCheckout.resolve(bundlePath: bundle + "/", files: files())?.root, root)
    }
}

final class BuildStampTests: XCTestCase {
    private let checkout = AppCheckout(
        root: "/Users/me/Projects/copper-agents-worker",
        bundlePath: "/Users/me/Projects/copper-agents-worker/.build/\(app)"
    )

    func testTheStampNamesTheCommitAndTheCheckoutItCameOutOf() {
        let sha = "891c38c914a6a6c4847012d14470a8b12089c542"
        let build = checkout.runningBuild(infoValue: sha)
        XCTAssertEqual(build?.commit, sha)
        XCTAssertEqual(build?.checkoutRoot, checkout.root)
    }

    func testAnUnstampedBundleClaimsNoBuild() {
        XCTAssertNil(checkout.runningBuild(infoValue: nil))
        XCTAssertNil(checkout.runningBuild(infoValue: ""))
        XCTAssertNil(checkout.runningBuild(infoValue: 42))
    }

    func testSomethingThatIsNotACommitIsNotPassedToGit() {
        XCTAssertNil(AppCheckout.commit(fromInfoValue: "not a sha"))
        XCTAssertNil(AppCheckout.commit(fromInfoValue: "891c38"), "shorter than git will resolve")
        XCTAssertNil(
            AppCheckout.commit(fromInfoValue: String(repeating: "a", count: 41)),
            "longer than a sha is not a sha"
        )
        XCTAssertNil(AppCheckout.commit(fromInfoValue: "HEAD"))
    }

    func testTheShaTheScriptWritesArrivesWithItsNewline() {
        XCTAssertEqual(AppCheckout.commit(fromInfoValue: " 891c38c9\n"), "891c38c9")
    }

    func testTheBuildCommitIsReadUnderItsKey() {
        let info = [AppCheckout.Layout.buildCommitKey: "891c38c9"]
        XCTAssertEqual(AppCheckout.buildCommit { info[$0] }, "891c38c9")
        XCTAssertNil(AppCheckout.buildCommit { _ in nil }, "a swift run build carries no stamp")
    }


    /// Nothing in either language checks the other, so the agreement is checked here.
    func testTheBuildScriptWritesTheKeyThisReadsBack() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent(AppCheckout.Layout.scriptPath)
        let text = try XCTUnwrap(try? String(contentsOf: script, encoding: .utf8),
                                "\(script.path) is where the checkout keeps the build script")

        XCTAssertTrue(
            text.contains(AppCheckout.Layout.buildCommitKey),
            "the script stopped writing \(AppCheckout.Layout.buildCommitKey), so no build can name itself"
        )
    }
}

/// Read off the script text, because nothing else can: the build runs once a
/// day at most, succeeds nearly every time, and the one ordering that matters
/// only shows itself on the run that fails.
final class BuildScriptOrderTests: XCTestCase {
    private func script() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = root.appendingPathComponent(AppCheckout.Layout.scriptPath)
        return try XCTUnwrap(try? String(contentsOf: path, encoding: .utf8),
                             "\(path.path) is where the checkout keeps the build script")
    }

    /// The one that bit: a GUI-launched Rebuild found no `node`, read the
    /// installed SDK as absent, and exited — having already deleted the bundle
    /// the running app was living out of. Everything that can still refuse has
    /// to refuse before anything is removed.
    func testNothingIsDeletedUntilTheSidecarHasBeenChecked() throws {
        let text = try script()

        guard let checked = text.range(of: "not installed intact"),
              let deleted = text.range(of: #"rm -rf "$APP""#)
        else { return XCTFail("the script no longer checks the SDK, or no longer stages the bundle") }

        XCTAssertTrue(
            checked.upperBound < deleted.lowerBound,
            "a failed build must leave the bundle the app is running out of alone"
        )
    }

    /// A GUI process inherits the launchd `PATH`, which has neither homebrew
    /// nor nvm on it, so a bare `node` is not there to be run.
    func testTheSdkVersionIsReadWithANodeThatWasSearchedFor() throws {
        let text = try script()

        XCTAssertTrue(text.contains(#""$NODE" -p "#), "the version read must use the resolved node")
        XCTAssertTrue(text.contains("/opt/homebrew/bin"), "PATH alone is not enough from the app")
        XCTAssertFalse(text.contains("\n    node -p "), "a bare node is whatever PATH happens to hold")
    }

    /// The host's node is fetched from nodejs.org, checked against the
    /// published sums, and put in a helper bundle that is signed before the
    /// bundle around it — all of it before the running app's bundle is touched.
    func testTheHostsNodeIsBundledSignedAndFetchedBeforeTheBundleIsReplaced() throws {
        let text = try script()

        let fetched = try XCTUnwrap(text.range(of: "SHASUMS256"))
        let deleted = try XCTUnwrap(text.range(of: "rm -rf \"$APP\""))
        XCTAssertTrue(fetched.upperBound < deleted.lowerBound, "a failed download must leave the bundle alone")

        XCTAssertTrue(text.contains("HELPER=\"$APP/Contents/Helpers/$HELPER_EXECUTABLE.app\""))
        XCTAssertTrue(text.contains("HELPER_EXECUTABLE=DexHost\n"))
        XCTAssertTrue(text.contains("HELPER_ID=\"$BUNDLE_ID.host\""))
        XCTAssertTrue(HostIdentity.code.helperExecutable.hasPrefix("Contents/Helpers/DexHost.app/"))

        let helperSigned = try XCTUnwrap(text.range(of: "--sign \"$1\" \"$HELPER\""))
        let appSigned = try XCTUnwrap(text.range(of: "--sign \"$1\" \"$APP\""))
        XCTAssertTrue(helperSigned.upperBound < appSigned.lowerBound, "nested code is sealed by the outer signature")
    }

    /// The script takes the app's id and bundle name off these lines with sed.
    func testTheScriptCanReadTheBundleIdentity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let swift = try String(
            contentsOf: root.appendingPathComponent("Sources/DexCore/Support/BundleIdentity.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(try script().contains("Sources/DexCore/Support/BundleIdentity.swift"))
        XCTAssertTrue(swift.contains("    public static let prefix = \"\(BundleIdentity.prefix)\"\n"))
        let suffix = BundleIdentity.code.dropFirst(BundleIdentity.prefix.count)
        XCTAssertTrue(swift.contains("    public static let code = prefix + \"\(suffix)\"\n"))
        XCTAssertTrue(swift.contains("    public static let codeBundle = \"\(BundleIdentity.codeBundle)\"\n"))
    }
}

final class RebuildCommandTests: XCTestCase {
    private let checkout = AppCheckout(
        root: "/Users/me/Projects/copper-agents-worker",
        bundlePath: "/Users/me/Projects/copper-agents-worker/.build/\(app)"
    )

    func testTheBuildRunsTheScriptThroughBashInRelease() {

        let spec = RebuildCommand.build(checkout, loginPath: nil, signingIdentity: nil)
        XCTAssertEqual(spec.executable, "/bin/bash")
        XCTAssertEqual(spec.arguments, [
            checkout.scriptPath, "release",
        ])
    }

    func testTheBuildRunsUnderTheLoginShellsPath() {
        let spec = RebuildCommand.build(checkout, loginPath: "/Users/me/.nvm/versions/node/v22/bin:/usr/bin",
                                        signingIdentity: nil)
        XCTAssertEqual(spec.environment, ["PATH": "/Users/me/.nvm/versions/node/v22/bin:/usr/bin"])
        XCTAssertEqual(RebuildCommand.build(checkout, loginPath: nil, signingIdentity: nil).environment, [:])
    }

    func testTheBuildSignsWithTheLoginShellsIdentityWhenItSetsOne() {
        let spec = RebuildCommand.build(checkout, loginPath: "/usr/bin", signingIdentity: "Dex Signing")
        XCTAssertEqual(spec.environment, ["PATH": "/usr/bin", "DEX_CODESIGN_IDENTITY": "Dex Signing"])
        XCTAssertNil(RebuildCommand.build(checkout, loginPath: "/usr/bin", signingIdentity: nil)
            .environment["DEX_CODESIGN_IDENTITY"])
    }

    func testTheRelaunchPassesThePidAndPathAsArgumentsNotAsScriptText() {

        let spec = RebuildCommand.relaunch(afterPID: 4242, bundlePath: "/tmp/it's here/\(app)")
        XCTAssertEqual(spec.executable, "/bin/sh")
        XCTAssertEqual(spec.arguments.first, "-c")
        XCTAssertEqual(spec.arguments.last, "/tmp/it's here/\(app)")
        XCTAssertTrue(spec.arguments.contains("4242"))

        let script = spec.arguments[1]
        XCTAssertFalse(script.contains("4242"), "the pid must not be in the script text")
        XCTAssertFalse(script.contains(app), "the path must not be in the script text")
        XCTAssertTrue(script.contains("kill -0"), "the relaunch must wait for this process to exit")
    }

    func testTheHostMarkerNamesTheSidecarEntryPoint() {
        XCTAssertEqual(RebuildCommand.hostMarker, "Sidecar/src/host.ts")
        XCTAssertTrue(
            HostLocation(socket: "/tmp/s.sock", entry: "/a/Sidecar/src/host.ts", node: "/bin/node")
                .entry.contains(RebuildCommand.hostMarker),
            "the marker must match the entry path the app launches the host with"
        )
    }

    func testTheInstalledBundleIsTheLastLineNotTheFirst() {

        let stdout = """
        Building for production...
        [1/12] Compiling DexCore SpinnerPhase.swift
        [12/12] Applying DexCode
        /Users/me/Projects/copper-agents-worker/.build/\(app)
        """
        XCTAssertEqual(
            RebuildCommand.installedBundle(fromStdout: stdout),
            "/Users/me/Projects/copper-agents-worker/.build/\(app)"
        )
    }

    func testTrailingBlankLinesDoNotHideTheBundlePath() {
        XCTAssertEqual(
            RebuildCommand.installedBundle(fromStdout: "/tmp/.build/\(app)\n\n  \n"),
            "/tmp/.build/\(app)"
        )
    }

    func testSomethingThatIsNotABundleIsNotAccepted() {

        XCTAssertNil(RebuildCommand.installedBundle(fromStdout: "Build complete! (7.51s)"))
        XCTAssertNil(RebuildCommand.installedBundle(fromStdout: ""))
        XCTAssertNil(RebuildCommand.installedBundle(fromStdout: "/tmp/Dex"))
    }

}

final class BuildLogTests: XCTestCase {
    private let progress = """
    Building for production...
    [1/12] Compiling DexCore AppCheckout.swift
    """

    func testItFindsTheDiagnosticAfterTheProgressLines() {
        let stderr = """
        /Users/me/Projects/copper-agents-worker/Sources/DexUI/SessionPresentation.swift:187:32: error: cannot find 'SpinnerPhase' in scope
        error: fatalError
        """
        XCTAssertEqual(
            BuildLog.failureMessage(stdout: progress, stderr: stderr, exitCode: 1),
            "SessionPresentation.swift:187:32: error: cannot find 'SpinnerPhase' in scope"
        )
    }

    func testTheLeadingPathIsCutToTheFileName() {

        let stderr = "/very/long/path/to/Sources/Thing.swift:9:1: error: expected '}'"
        XCTAssertEqual(
            BuildLog.failureMessage(stdout: "", stderr: stderr, exitCode: 1),
            "Thing.swift:9:1: error: expected '}'"
        )
    }

    func testAMessageThatOnlyMentionsAPathKeepsIt() {

        let stderr = "error: no such module at /opt/homebrew/lib/Foo.swiftmodule"
        XCTAssertEqual(
            BuildLog.failureMessage(stdout: "", stderr: stderr, exitCode: 1),
            stderr
        )
    }

    func testAFailureWithNoDiagnosticStillReportsSomething() {

        XCTAssertEqual(
            BuildLog.failureMessage(stdout: progress, stderr: "make-app.sh: line 14: swift: command not found", exitCode: 127),
            "make-app.sh: line 14: swift: command not found"
        )
    }

    func testWithNothingOnStderrItFallsBackToStdout() {
        XCTAssertEqual(
            BuildLog.failureMessage(stdout: progress, stderr: "", exitCode: 1),
            "[1/12] Compiling DexCore AppCheckout.swift"
        )
    }

    func testWithNothingAtAllItReportsTheExitCode() {

        XCTAssertEqual(BuildLog.failureMessage(stdout: "", stderr: "", exitCode: 2), "exited 2")
    }
}

/// Rebuild and Restart builds the checkout as it stands. A checkout behind its
/// origin stays behind, and nothing is fetched.
final class RebuildRunsNoGitTests: XCTestCase {
    private var root: URL!
    private var here: String { root.appendingPathComponent("here").path }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rebuild-no-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let origin = root.appendingPathComponent("origin.git").path
        let there = root.appendingPathComponent("there").path
        git(root.path, "init", "-q", "--bare", "-b", "main", origin)
        git(root.path, "clone", "-q", origin, here)
        commit(here, "base")
        git(here, "push", "-q", "origin", "main")
        git(root.path, "clone", "-q", origin, there)
        commit(there, "ahead")
        git(there, "push", "-q", "origin", "main")

        let script = URL(fileURLWithPath: AppCheckout.Layout.script(in: here))
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "echo \"$PWD/.build/\(app)\"\n".write(to: script, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ directory: String, _ arguments: String...) -> String {
        let result = try? Shell.run(
            ["git", "-C", directory, "-c", "user.name=t", "-c", "user.email=t@t"] + arguments
        )
        return result?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func commit(_ directory: String, _ name: String) {
        try? name.write(toFile: "\(directory)/\(name).txt", atomically: true, encoding: .utf8)
        git(directory, "add", ".")
        git(directory, "commit", "-q", "-m", name)
    }

    func testTheBuildLeavesTheCheckoutWhereItWas() {
        let head = git(here, "rev-parse", "HEAD")
        let tracked = git(here, "rev-parse", "origin/main")
        XCTAssertFalse(head.isEmpty)
        let phases = Lock([String]())

        let result = RebuildRunner(checkout: AppCheckout(root: here, bundlePath: "\(here)/.build/\(app)"))
            .build { phase in phases.withLock { $0.append(phase) } }

        XCTAssertTrue(result.outcome.succeeded, result.outcome.message)
        XCTAssertEqual(result.installedBundle?.hasSuffix("/here/.build/\(app)"), true)
        XCTAssertEqual(git(here, "rev-parse", "HEAD"), head)
        XCTAssertEqual(git(here, "rev-parse", "origin/main"), tracked, "nothing was fetched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(here)/ahead.txt"))
        XCTAssertFalse(phases.withLock { $0 }.contains { $0.contains("pull") })
    }
}
