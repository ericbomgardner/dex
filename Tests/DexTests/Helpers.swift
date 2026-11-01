import XCTest
@testable import DexCore

struct EveryDirectoryExists: DirectoryProbe {
    func sighting(at path: String) -> DirectorySighting { .directory }
}

func makeSession(
    _ name: String,
    state: HostSessionState,
    startedAt: Double = 1_000_000,
    hostPID: Int? = nil,
    cwd: String? = nil
) -> AgentSession {
    AgentSession(
        cwd: cwd ?? "/tmp/\(name)",
        startedAt: startedAt,
        hostKey: name,
        state: state,
        hostPID: hostPID,
        sessionId: "uuid-\(name)",
        name: name
    )
}

func makeRow(
    _ name: String,
    state: HostSessionState,
    startedAt: Double = 1_000_000,
    hostPID: Int? = nil,
    cwd: String? = nil,
    worktree: WorktreeOrigin? = nil,
    lastActivityAt: Date? = nil,
    pinnedUpdate: Date? = nil,
    livePermissionMode: String? = nil,
    owesTurn: Bool = false,
    hostedSummary: String? = nil,
    runningTasks: Int = 0
) -> SessionRowModel {
    SessionRowModel(
        session: makeSession(name, state: state, startedAt: startedAt, hostPID: hostPID, cwd: cwd),
        worktree: worktree,
        lastActivityAt: lastActivityAt,
        pinnedUpdate: pinnedUpdate,
        livePermissionMode: livePermissionMode,
        owesTurn: owesTurn,
        hostedSummary: hostedSummary,
        runningTasks: runningTasks
    )
}
