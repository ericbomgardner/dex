import XCTest
@testable import DexCore

final class ProjectExistenceTests: XCTestCase {

    func testFileSystemProbeSeesARealDirectory() throws {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("project-existence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let probe = FileSystemDirectoryProbe()
        XCTAssertEqual(probe.sighting(at: temporary.path), .directory)
        XCTAssertTrue(probe.stillThere(temporary.path))

        try FileManager.default.removeItem(at: temporary)
        XCTAssertEqual(probe.sighting(at: temporary.path), .missing)
        XCTAssertFalse(probe.stillThere(temporary.path))
    }

    /// A folder macOS is withholding fails to stat exactly as a deleted one does,
    /// which is what a blocked parent stands in for here.
    func testFileSystemProbeWithholdsWhatItIsNotAllowedToSee() throws {
        let blocked = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("project-existence-\(UUID().uuidString)")
        let project = blocked.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: blocked)
        }

        let probe = FileSystemDirectoryProbe()
        XCTAssertEqual(probe.sighting(at: project.path), .directory)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        XCTAssertEqual(probe.sighting(at: project.path), .withheld)
        XCTAssertTrue(probe.stillThere(project.path),
                      "a project macOS won't talk about is not a deleted one")
    }

    func testFileSystemProbeRejectsAFileMasqueradingAsAProject() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("project-existence-\(UUID().uuidString).txt")
        try Data("not a repo".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(FileSystemDirectoryProbe().sighting(at: file.path), .missing)
    }
}
