import Foundation

/// The names `--permission-mode` takes, read off the CLI by
/// `Scripts/permission-mode-probe.py` — `claude --help` prints them as that
/// flag's `choices`. Recorded against **CLI v2.1.316**; re-run the probe when
/// the CLI moves and the list will move with it.
///
/// The list says what to offer, not what to allow: a name that falls off it
/// still dispatches. `default` is not in here — sending no flag already means
/// that, and the picker says so in words.
public enum PermissionModes {

    public static let version = "2.1.316"

    public static let all: [String] = [
        "acceptEdits",
        "auto",
        "bypassPermissions",
        "manual",
        "dontAsk",
        "plan",
    ]

    /// What a transcript writes, which is not what the flag takes: `default` is
    /// written often and the flag refuses it, while `manual`, `dontAsk` and
    /// `bypassPermissions` are the other way round. A mode is only unrecognised
    /// if it is in neither — reading `default` as a name this build has never
    /// heard of would mark most of the list.
    public static let written: [String] = [
        "auto",
        "default",
        "acceptEdits",
        "plan",
    ]

    public static func recognises(_ name: String) -> Bool {
        all.contains(name) || written.contains(name)
    }
}
