import Foundation

/// The CLI's own register of live sessions — one `<pid>.json` under
/// `~/.claude/sessions`, written by the session it describes. It carries the
/// name other sessions message that session by, which the transcript never
/// does: the fleet file's `name` is the transcript's title, a label, and this
/// is the address. The session id is the join between the two.
public enum SessionRegistry {

    public static func directory(configDirectory: URL = ConfigDirectory.resolve()) -> URL {
        configDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// What the CLI says of a live session: the name it is messaged by, the
    /// folder it is in now (which follows it into a worktree, where the
    /// transcript's launch folder does not), and whether the name is only the
    /// one the CLI made up from that folder.
    public struct Entry: Sendable, Equatable {
        public let address: String
        public let cwd: String?
        public let isDerived: Bool

        public init(address: String, cwd: String? = nil, isDerived: Bool = false) {
            self.address = address
            self.cwd = cwd
            self.isDerived = isDerived
        }
    }

    /// Entry by session id, for every record whose process is alive.
    /// The `.key` files beside the records are skipped by name, and a record
    /// naming no session or no address is skipped rather than guessed at.
    public static func entries(in directory: URL) -> [String: Entry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return [:]
        }
        var entries: [String: Entry] = [:]
        for name in names where isRecord(name) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  let sessionId = record.sessionId,
                  let address = record.name, !address.isEmpty,
                  isAlive(record.pid)
            else { continue }
            entries[sessionId] = Entry(
                address: address,
                cwd: record.cwd.flatMap { $0.isEmpty ? nil : $0 },
                isDerived: record.nameSource == "derived"
            )
        }
        return entries
    }

    public static func addresses(in directory: URL) -> [String: String] {
        entries(in: directory).mapValues(\.address)
    }

    static func isRecord(_ filename: String) -> Bool {
        let stem = filename.dropLast(5)
        return filename.hasSuffix(".json") && !stem.isEmpty && stem.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// A session sweeps its own record on exit, but a crash leaves one behind
    /// naming a process that is gone — and, given long enough, a process that
    /// is someone else. A record with no pid is believed.
    static func isAlive(_ pid: Int?) -> Bool {
        guard let pid else { return true }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    private struct Record: Decodable {
        let pid: Int?
        let sessionId: String?
        let name: String?
        let nameSource: String?
        let cwd: String?
    }
}
