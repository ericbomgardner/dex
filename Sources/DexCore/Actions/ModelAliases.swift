import Foundation

/// The names `--model` takes, read off the CLI by
/// `Scripts/model-alias-probe.py` — `claude -p "/model"` prints them under
/// `Available:`. Recorded against **CLI v2.1.316**; re-run the probe when the
/// CLI moves and the list will move with it.
///
/// The CLI takes a full model id as well, so this says what to offer rather than
/// what to allow — a name that falls off the list still dispatches. `default` is
/// not in here: sending no flag already means that.
public enum ModelAliases {

    public static let version = "2.1.316"

    public static let all: [String] = [
        "sonnet",
        "opus",
        "haiku",
        "fable",
        "best",
        "sonnet[1m]",
        "opus[1m]",
        "fable[1m]",
        "opusplan",
    ]
}
