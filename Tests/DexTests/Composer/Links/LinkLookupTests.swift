import XCTest
@testable import DexCore

final class GitHubLinkLookupTests: XCTestCase {

    private let pr = PastedLink(url: "https://github.com/acme/app/pull/12/files?w=1")!
    private let issue = PastedLink(url: "https://github.com/acme/app/issues/7")!

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func answering(_ stdout: Data, exit: Int32 = 0, stderr: String = "") -> (GitHubLinkLookup, Lock<[String]>) {
        let asked = Lock<[String]>([])
        let lookup = GitHubLinkLookup { arguments in
            asked.value = arguments
            return CommandResult(stdout: stdout, stderr: stderr, exitCode: exit)
        }
        return (lookup, asked)
    }

    func testAsksTheIssuesEndpointForAPullRequestToo() async throws {
        let (lookup, asked) = answering(json(["title": "Fix", "state": "open", "pull_request": ["merged_at": NSNull()]]))
        _ = try await lookup.resolve(pr)
        XCTAssertEqual(asked.value.first, "api")
        XCTAssertEqual(asked.value.last, "repos/acme/app/issues/12")
    }

    func testAMergedPullRequest() async throws {
        let (lookup, _) = answering(json([
            "title": "Fix the sidebar", "state": "closed", "draft": false,
            "pull_request": ["merged_at": "2026-09-01T00:00:00Z"],
        ]))
        let found = try await lookup.resolve(pr)
        XCTAssertEqual(found, LinkResolution(title: "Fix the sidebar", detail: "PR acme/app#12 · merged", state: .merged))
    }

    func testAClosedUnmergedPullRequest() {
        let found = try? GitHubIssue.parse(json(["title": "t", "state": "closed", "pull_request": ["merged_at": NSNull()]]),
                                           link: GitHubLink(url: "https://github.com/a/b/pull/1", host: "github.com", path: ["a", "b", "pull", "1"])!)
        XCTAssertEqual(found?.state, .closed)
        XCTAssertEqual(found?.detail, "PR a/b#1 · closed")
    }

    func testADraftPullRequest() async throws {
        let (lookup, _) = answering(json(["title": "t", "state": "open", "draft": true, "pull_request": [:] as [String: Any]]))
        let found = try await lookup.resolve(pr)
        XCTAssertEqual(found?.state, .draft)
    }

    func testIssuesClosedAsDoneAndAsNotPlanned() async throws {
        var (lookup, _) = answering(json(["title": "Bug", "state": "closed", "state_reason": "completed"]))
        var found = try await lookup.resolve(issue)
        XCTAssertEqual(found, LinkResolution(title: "Bug", detail: "Issue acme/app#7 · closed", state: .done))

        (lookup, _) = answering(json(["title": "Bug", "state": "closed", "state_reason": "not_planned"]))
        found = try await lookup.resolve(issue)
        XCTAssertEqual(found?.state, .closed)
        XCTAssertEqual(found?.detail, "Issue acme/app#7 · not planned")

        (lookup, _) = answering(json(["title": "Bug", "state": "open", "state_reason": NSNull()]))
        found = try await lookup.resolve(issue)
        XCTAssertEqual(found?.state, .open)
    }

    func testNoGhIsNothingToAskWith() async throws {
        let lookup = GitHubLinkLookup { _ in nil }
        let found = try await lookup.resolve(pr)
        XCTAssertNil(found)
    }

    func testALoggedOutGhIsNothingToAskWith() async throws {
        let (lookup, _) = answering(Data(), exit: 4, stderr: "To get started with GitHub CLI, please run:  gh auth login")
        let found = try await lookup.resolve(pr)
        XCTAssertNil(found)
    }

    func testANotFoundIsAFailure() async {
        let (lookup, _) = answering(Data(#"{"message":"Not Found"}"#.utf8), exit: 1, stderr: "gh: Not Found (HTTP 404)")
        do {
            _ = try await lookup.resolve(pr)
            XCTFail("a 404 should throw")
        } catch {
            XCTAssertEqual(error as? PastedLinkError, .service("gh: Not Found (HTTP 404)"))
        }
    }

    func testOtherServicesArePassedOver() async throws {
        let (lookup, asked) = answering(Data())
        let found = try await lookup.resolve(PastedLink(url: "https://linear.app/a/issue/A-1")!)
        XCTAssertNil(found)
        XCTAssertTrue(asked.value.isEmpty)
    }

    // Finding gh

    func testTheLoginShellsPathComesFirst() {
        let found = GitHubCLI.locate(
            loginPath: "/Users/me/bin:/opt/homebrew/bin",
            processPath: "/usr/bin:/bin",
            isExecutable: { ["/opt/homebrew/bin/gh", "/usr/bin/gh"].contains($0) })
        XCTAssertEqual(found, "/opt/homebrew/bin/gh")
    }

    func testWithoutALoginShellTheUsualPlacesAreTried() {
        let found = GitHubCLI.locate(
            loginPath: nil,
            processPath: "/usr/bin:/bin:/usr/sbin:/sbin",
            isExecutable: { $0 == "/usr/local/bin/gh" })
        XCTAssertEqual(found, "/usr/local/bin/gh")
    }

    func testATildeFallbackIsExpanded() {
        let home = NSHomeDirectory()
        let found = GitHubCLI.locate(loginPath: nil, processPath: nil,
                                     isExecutable: { $0 == home + "/.local/bin/gh" })
        XCTAssertEqual(found, home + "/.local/bin/gh")
    }

    func testNoGhAnywhere() {
        XCTAssertNil(GitHubCLI.locate(loginPath: "/a", processPath: "/b", isExecutable: { _ in false }))
    }
}

final class PastedLinkResolverTests: XCTestCase {

    private struct Counting: ExternalLinkLookup {
        let calls = Lock(0)
        let answer: LinkResolution?
        var fails = false

        func resolve(_ link: PastedLink) async throws -> LinkResolution? {
            calls.withLock { $0 += 1 }
            if fails { throw PastedLinkError.notFound }
            return answer
        }
    }

    private let pr = PastedLink(url: "https://github.com/acme/app/pull/12")!

    func testALookupIsRememberedWhileFresh() async {
        let lookup = Counting(answer: LinkResolution(title: "Fix"))
        let resolver = PastedLinkResolver(lookups: [.github: lookup], freshFor: 60)
        let start = Date(timeIntervalSince1970: 0)
        let first = await resolver.resolve(pr, now: start)
        let again = await resolver.resolve(pr, now: start.addingTimeInterval(30))
        XCTAssertEqual(first?.title, "Fix")
        XCTAssertEqual(again?.title, "Fix")
        XCTAssertEqual(lookup.calls.value, 1)
        _ = await resolver.resolve(pr, now: start.addingTimeInterval(90))
        XCTAssertEqual(lookup.calls.value, 2)
    }

    func testAFailureIsNilAndAskedAgainNextTime() async {
        let lookup = Counting(answer: nil, fails: true)
        let resolver = PastedLinkResolver(lookups: [.github: lookup])
        let first = await resolver.resolve(pr)
        XCTAssertNil(first)
        _ = await resolver.resolve(pr)
        XCTAssertEqual(lookup.calls.value, 2)
    }

    func testAServiceWithNoLookupIsNil() async {
        let resolver = PastedLinkResolver()
        let found = await resolver.resolve(PastedLink(url: "https://linear.app/a/issue/A-1")!)
        XCTAssertNil(found)
    }

    func testInstallingALookupForgetsWhatTheOldOneSaid() async {
        let resolver = PastedLinkResolver(lookups: [.github: Counting(answer: LinkResolution(title: "old"))])
        _ = await resolver.resolve(pr)
        await resolver.install(Counting(answer: LinkResolution(title: "new")), for: .github)
        let found = await resolver.resolve(pr)
        XCTAssertEqual(found?.title, "new")
    }
}
