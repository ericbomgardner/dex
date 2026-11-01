import XCTest
@testable import DexCore

final class ComposerStashTests: XCTestCase {
    private var written: [URL] = []

    override func tearDown() {
        for url in written {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        written = []
        super.tearDown()
    }

    private func stash(_ name: String, _ ext: String) throws -> ComposerAttachment {
        let attachment = try ComposerStash.save(Data("pixels".utf8), named: name, extension: ext)
        written.append(URL(fileURLWithPath: attachment.path))
        return attachment
    }

    func testAStashedImageLandsSomewhereAReadCanFindIt() throws {
        let attachment = try stash("shot.png", "png")

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: attachment.path)),
                       Data("pixels".utf8))
        XCTAssertTrue(attachment.path.hasPrefix(ComposerStash.directory.path),
                      "\(attachment.path) is not under the app's stash")
    }

    func testTheDraggedNameIsKeptSoTheChipReadsWell() throws {
        XCTAssertEqual(try stash("diagram.jpeg", "png").name, "diagram.png")
    }

    func testAnUnnamedDropStillGetsAReadableName() throws {
        XCTAssertEqual(try stash("", "png").name, "\(ComposerStash.fallbackName).png")
        XCTAssertEqual(try stash("   ", "gif").name, "\(ComposerStash.fallbackName).gif")
    }

    func testTwoDropsOfTheSameNameDoNotOverwriteEachOther() throws {
        let first = try stash("shot.png", "png")
        let second = try stash("shot.png", "png")

        XCTAssertNotEqual(first.path, second.path)
        XCTAssertEqual(first.name, second.name)
    }

    func testASlashInTheDraggedNameCannotEscapeTheStash() throws {
        let attachment = try stash("../../evil", "png")

        XCTAssertEqual(URL(fileURLWithPath: attachment.path)
            .deletingLastPathComponent()
            .deletingLastPathComponent().standardizedFileURL.path,
            ComposerStash.directory.standardizedFileURL.path)
    }

    func testTheScreenshotThumbnailsFileIsReadAsBorrowed() {
        let thumbnail = "/var/folders/7m/f4s2_r6953x71l6twt9xz5t00000gn/T/TemporaryItems"
            + "/NSIRD_screencaptureui_bec56H/Screenshot 2026-09-06 at 6.55.24 PM.png"

        XCTAssertTrue(ComposerStash.isBorrowed(thumbnail))
        XCTAssertTrue(ComposerStash.isBorrowed("/private" + thumbnail),
                      "/var is a symlink, so the same file arrives spelled two ways")
    }

    func testAFileTheUserOwnsIsLeftWhereItLies() {
        XCTAssertFalse(ComposerStash.isBorrowed("/Users/me/Desktop/shot.png"))
        XCTAssertFalse(ComposerStash.isBorrowed("/Users/me/Projects/app/Sources/Main.swift"))
    }

    func testWhatIsAlreadyStashedIsNotBorrowedFromOurselves() throws {
        XCTAssertTrue(ComposerStash.directory.path.hasPrefix(NSTemporaryDirectory()),
                      "the stash sits in the scratch space it is meant to rescue files from")
        XCTAssertFalse(ComposerStash.isBorrowed(try stash("shot.png", "png").path))
    }

    func testASandboxedTemporaryDirectoryCountsTooEvenOutsideVarFolders() {
        XCTAssertTrue(ComposerStash.isBorrowed("/some/container/tmp/dropped.png",
                                               temporaryDirectory: "/some/container/tmp"))
    }

    func testKeepingABorrowedFileSurvivesTheOriginalGoingAway() throws {
        let lent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NSIRD_screencaptureui_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: lent, withIntermediateDirectories: true)
        let source = lent.appendingPathComponent("Screenshot 2026-09-06 at 6.55.24 PM.png")
        try Data("pixels".utf8).write(to: source)

        let attachment = try ComposerStash.keep(source.path)
        written.append(URL(fileURLWithPath: attachment.path))
        try FileManager.default.removeItem(at: lent)

        XCTAssertEqual(attachment.name, "Screenshot 2026-09-06 at 6.55.24 PM.png")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: attachment.path)),
                       Data("pixels".utf8))
        XCTAssertEqual(ComposerAttachments.present([attachment]), [attachment])
    }

    func testAFileAlreadyTakenBackLeavesNoEmptyFolderInTheStash() throws {
        let gone = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NSIRD_screencaptureui_\(UUID().uuidString)/shot.png")

        let before = try stashedFolders()
        XCTAssertThrowsError(try ComposerStash.keep(gone.path))
        XCTAssertEqual(try stashedFolders(), before)
    }

    private func stashedFolders() throws -> Set<String> {
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: ComposerStash.directory.path)
        else { return [] }
        return Set(names)
    }

    func testAScreenshotIsKeptUnderANameThatCanBeTypedBack() throws {
        let lent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NSIRD_screencaptureui_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: lent, withIntermediateDirectories: true)
        let source = lent.appendingPathComponent("Screenshot 2026-09-07 at 11.30.23\u{202F}PM.png")
        try Data("pixels".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: lent) }

        let attachment = try ComposerStash.keep(source.path)
        written.append(URL(fileURLWithPath: attachment.path))

        XCTAssertEqual(attachment.name, "Screenshot 2026-09-07 at 11.30.23 PM.png")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: attachment.path)),
                       Data("pixels".utf8))
    }

    func testAnOrdinaryNameIsLeftExactlyAsItWasDropped() {
        XCTAssertTrue(ComposerStash.typesAsWritten("/Users/me/Desktop/shot (2).png"))
        XCTAssertTrue(ComposerStash.typesAsWritten("/Users/me/Desktop/Screen Shot 1.png"))
        XCTAssertTrue(ComposerStash.typesAsWritten("/Users/me/Desktop/ninetales.png"))
    }

    func testANameNobodyCanSeeTheDifferenceInIsCaught() {
        XCTAssertFalse(ComposerStash.typesAsWritten(
            "/Users/me/Desktop/Screenshot 2026-09-07 at 11.34.01\u{202F}PM.png"))
        XCTAssertFalse(ComposerStash.typesAsWritten("/Users/me/Desktop/shot\u{00A0}1.png"))
        XCTAssertFalse(ComposerStash.typesAsWritten("/Users/me/Desktop/shot\u{200B}.png"),
                       "an invisible carries nothing a reader could type")
        XCTAssertFalse(ComposerStash.typesAsWritten("/Users/me/Desk\u{202F}top/shot.png"),
                       "a folder carries the character just as a file does")
    }

    func testAFileStayingWhereItLiesIsPointedAtUnderAPlainName() throws {
        let desktop = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("desktop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let source = desktop.appendingPathComponent("Screenshot 2026-09-07 at 11.34.01\u{202F}PM.png")
        try Data("pixels".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: desktop) }

        let attachment = try ComposerStash.link(source.path)
        written.append(URL(fileURLWithPath: attachment.path))

        XCTAssertEqual(attachment.name, "Screenshot 2026-09-07 at 11.34.01 PM.png")
        XCTAssertTrue(ComposerStash.typesAsWritten(attachment.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: attachment.path)),
                       Data("pixels".utf8))
        XCTAssertEqual(ComposerAttachments.present([attachment]), [attachment])
    }

    func testALinkToAFileThatMovedReadsAsGoneRatherThanAsAttached() throws {
        let source = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moved-\(UUID().uuidString)/shot\u{202F}1.png")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("pixels".utf8).write(to: source)

        let attachment = try ComposerStash.link(source.path)
        written.append(URL(fileURLWithPath: attachment.path))
        try FileManager.default.removeItem(at: source.deletingLastPathComponent())

        XCTAssertEqual(ComposerAttachments.present([attachment]), [])
    }

    func testALinkToAFileAlreadyGoneLeavesNoEmptyFolderInTheStash() throws {
        let gone = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gone-\(UUID().uuidString)")

        _ = try? ComposerStash.link(gone.appendingPathComponent("shot.png").path)
        let before = try stashedFolders()
        _ = try? ComposerStash.link(gone.appendingPathComponent("shot.png").path)

        XCTAssertEqual(try stashedFolders(), before,
                       "a link that cannot be made takes its folder with it")
    }

    func testTwoBorrowedFilesOfTheSameNameDoNotOverwriteEachOther() throws {
        let source = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shot-\(UUID().uuidString).png")
        try Data("pixels".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let first = try ComposerStash.keep(source.path)
        let second = try ComposerStash.keep(source.path)
        written.append(contentsOf: [first, second].map { URL(fileURLWithPath: $0.path) })

        XCTAssertNotEqual(first.path, second.path)
        XCTAssertEqual(first.name, second.name)
    }
}
