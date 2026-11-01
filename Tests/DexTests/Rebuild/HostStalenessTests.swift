import XCTest

@testable import DexCore

/// When the app may end a host on its own: newer than the one holding the
/// socket, and nothing running to lose.
final class HostStalenessTests: XCTestCase {

    // Behind

    func testDifferingBuildStampsAreBehind() {
        XCTAssertTrue(
            HostStaleness.isBehind(appBuild: "aaaaaaa", hostBuild: "bbbbbbb", sdk: nil)
        )
    }

    func testMatchingBuildStampsAreNotBehind() {
        XCTAssertFalse(
            HostStaleness.isBehind(appBuild: "aaaaaaa", hostBuild: "aaaaaaa", sdk: nil)
        )
    }

    /// Two absent stamps are a checkout or a host from before the field, not a
    /// match — the whole safety of the automatic path is that this never fires.
    func testNilStampsAreNotBehind() {
        XCTAssertFalse(HostStaleness.isBehind(appBuild: nil, hostBuild: nil, sdk: nil))
        XCTAssertFalse(HostStaleness.isBehind(appBuild: "aaaaaaa", hostBuild: nil, sdk: nil))
        XCTAssertFalse(HostStaleness.isBehind(appBuild: nil, hostBuild: "bbbbbbb", sdk: nil))
    }

    /// The SDK pair still catches a host from before the app carried a build
    /// stamp at all: matching-or-nil stamps, but an older loaded SDK.
    func testTheSDKGapIsBehindOnItsOwn() {
        let sdk = HostSDK(loaded: "0.3.251", onDisk: "0.3.257")
        XCTAssertTrue(HostStaleness.isBehind(appBuild: nil, hostBuild: nil, sdk: sdk))
    }

    func testASameSDKIsNotBehind() {
        let sdk = HostSDK(loaded: "0.3.257", onDisk: "0.3.257")
        XCTAssertFalse(HostStaleness.isBehind(appBuild: nil, hostBuild: nil, sdk: sdk))
    }

    // The whole decision

    func testStaleAndIdleReplaces() {
        XCTAssertTrue(
            HostStaleness.shouldReplace(
                appBuild: "aaaaaaa", hostBuild: "bbbbbbb", sdk: nil, busy: false
            )
        )
    }

    func testStaleButBusyWaits() {
        XCTAssertFalse(
            HostStaleness.shouldReplace(
                appBuild: "aaaaaaa", hostBuild: "bbbbbbb", sdk: nil, busy: true
            )
        )
    }

    /// A host too old to send the field can't be judged safe to stop, so nil
    /// waits — the first upgrade onto a build with this still needs the menu.
    func testStaleButSilentOnBusyWaits() {
        XCTAssertFalse(
            HostStaleness.shouldReplace(
                appBuild: "aaaaaaa", hostBuild: "bbbbbbb", sdk: nil, busy: nil
            )
        )
    }

    func testCurrentAndIdleLeavesItAlone() {
        XCTAssertFalse(
            HostStaleness.shouldReplace(
                appBuild: "aaaaaaa", hostBuild: "aaaaaaa", sdk: nil, busy: false
            )
        )
    }

    /// The host that comes back after a replace is respawned from the bundle
    /// on disk. If it is the very host just ended, that bundle is not this
    /// app's — the .app was swapped under a running copy — and ending it again
    /// only gets it again. One host did that once a second for forty minutes.
    func testTheSameHostComingBackAfterAReplaceIsLeftAlone() {
        let replaced = HostStaleness.signature(hostBuild: "bbbbbbb", sdk: nil)
        XCTAssertFalse(
            HostStaleness.shouldReplace(
                appBuild: "aaaaaaa", hostBuild: "bbbbbbb", sdk: nil, busy: false,
                afterReplacing: replaced
            )
        )
        XCTAssertTrue(
            HostStaleness.shouldReplace(
                appBuild: "aaaaaaa", hostBuild: "ccccccc", sdk: nil, busy: false,
                afterReplacing: replaced
            ),
            "a different host is judged on its own"
        )
    }

    /// With no build stamps the SDK the host loaded is the only thing that
    /// names it, so the same guard holds on that path.
    func testTheSameSDKComingBackAfterAReplaceIsLeftAlone() {
        let sdk = HostSDK(loaded: "0.3.251", onDisk: "0.3.257")
        let replaced = HostStaleness.signature(hostBuild: nil, sdk: sdk)
        XCTAssertEqual(replaced, "0.3.251")
        XCTAssertFalse(
            HostStaleness.shouldReplace(
                appBuild: nil, hostBuild: nil, sdk: sdk, busy: false, afterReplacing: replaced
            )
        )
    }

    /// The SDK gap is enough to act on when neither side carries a stamp — the
    /// path that replaces a host from before the build-stamp field.
    func testSDKBehindAndIdleReplaces() {
        let sdk = HostSDK(loaded: "0.3.251", onDisk: "0.3.257")
        XCTAssertTrue(
            HostStaleness.shouldReplace(appBuild: nil, hostBuild: nil, sdk: sdk, busy: false)
        )
    }
}
