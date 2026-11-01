import Foundation

public enum AttachedSession {

    /// The detail pane holds one session and follows the list: filtering to a
    /// different project, or resolving the session, takes it off screen.
    public static func isOutOfView(
        _ row: SessionRowModel,
        project: String?,
        resolutions: SessionResolutions
    ) -> Bool {
        if let project, !project.isEmpty, row.projectPath != project { return true }
        return resolutions.isSettled(row)
    }
}
