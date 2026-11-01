import XCTest
@testable import DexCore

final class HostSDKTests: XCTestCase {

    func testAHostStartedUnderAnOlderBuildIsBehind() {
        let sdk = HostSDK(loaded: "0.3.227", onDisk: "0.3.238")
        XCTAssertTrue(sdk.isBehind)
    }

    func testAHostOnTheBuildBesideItSaysNothing() {
        let sdk = HostSDK(loaded: "0.3.238", onDisk: "0.3.238")
        XCTAssertFalse(sdk.isBehind)
    }

    /// Which happens on a checkout built from an older commit: the pin moves
    /// with the build, so the bundle on disk can be behind the process. Not
    /// something to offer a restart for, and not a negative span either.
    func testAHostAheadOfTheBundleIsNotBehind() {
        XCTAssertFalse(HostSDK(loaded: "0.3.238", onDisk: "0.3.227").isBehind)
    }

    /// Compared as numbers, which is the reason this doesn't just compare
    /// strings: 0.3.9 sorts below 0.3.10, and text says the opposite.
    func testComparedAsNumbersRatherThanAsText() {
        XCTAssertTrue(HostSDK(loaded: "0.3.9", onDisk: "0.3.10").isBehind)
        XCTAssertFalse(HostSDK(loaded: "0.3.10", onDisk: "0.3.9").isBehind)
    }

    /// A host from before the field says nothing about itself, and is left
    /// saying nothing — a guess here would replace a host that may well be
    /// current.
    func testAHostThatDoesNotSayIsNotAccused() {
        let sdk = HostSDK(loaded: "0.3.227", onDisk: nil)
        XCTAssertFalse(sdk.isBehind)
    }

    func testAVersionThatDoesNotParseIsNotAccused() {
        XCTAssertFalse(HostSDK(loaded: "unknown", onDisk: "0.3.238").isBehind)
        XCTAssertFalse(HostSDK(loaded: "0.3.227", onDisk: "unknown").isBehind)
    }
}
