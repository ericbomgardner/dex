import Foundation

/// A command's description put in the tense of the rest of a run's sentence:
/// the model writes "Run the tests", the run says "ran the tests".
///
/// Only the opening word and a word straight after "and", "then" or a comma
/// are turned ("Commit, merge and push"), and only when it is a verb these
/// descriptions are known to use; anything else ("Latest logs") stays as
/// written. Past the opening, a word that is mostly a noun in them stays too:
/// "Show status, diff and log". `transcript-render.py` has the same lists;
/// keep the two in step.
enum PastTense {

    static func of(_ clause: String) -> String {
        var words = clause.components(separatedBy: " ")
        for index in words.indices where index == 0 || opensClause(after: words[index - 1]) {
            var word = words[index]
            var trail = ""
            while let last = word.last, ",.:;".contains(last) {
                trail = String(last) + trail
                word.removeLast()
            }
            if index > 0, mostlyNouns.contains(word.lowercased()) { continue }
            if let turned = turned(word) { words[index] = turned + trail }
        }
        return words.joined(separator: " ")
    }

    private static func opensClause(after word: String) -> Bool {
        word == "and" || word == "then" || word.hasSuffix(",")
    }

    /// The word in the past, keeping its first letter's case, or nil when it
    /// isn't a verb on the list. "Re-run" turns on its last part.
    private static func turned(_ word: String) -> String? {
        let lower = word.lowercased()
        var past = pastOf(lower)
        if past == nil, let dash = lower.lastIndex(of: "-") {
            past = pastOf(String(lower[lower.index(after: dash)...])).map { lower[...dash] + $0 }
        }
        guard let past else { return nil }
        return word.first?.isUppercase == true ? past.prefix(1).uppercased() + past.dropFirst() : past
    }

    private static func pastOf(_ verb: String) -> String? {
        if let irregular = irregular[verb] { return irregular }
        guard regular.contains(verb) else { return nil }
        if doubled.contains(verb) { return verb + String(verb.last!) + "ed" }
        if verb.hasSuffix("e") { return verb + "d" }
        if verb.hasSuffix("y"), let before = verb.dropLast().last, !"aeiou".contains(before) {
            return verb.dropLast() + "ied"
        }
        return verb + "ed"
    }

    static let irregular: [String: String] = [
        "read": "read", "reread": "reread", "find": "found", "run": "ran", "rerun": "reran",
        "build": "built", "rebuild": "rebuilt", "see": "saw", "get": "got", "make": "made",
        "write": "wrote", "rewrite": "rewrote", "give": "gave", "set": "set", "reset": "reset",
        "quit": "quit", "break": "broke", "bring": "brought", "teach": "taught", "split": "split",
        "keep": "kept", "draw": "drew", "redraw": "redrew", "put": "put", "let": "let",
        "hold": "held", "send": "sent", "resend": "resent", "cut": "cut", "catch": "caught",
        "take": "took", "do": "did", "redo": "redid", "undo": "undid", "go": "went",
        "begin": "began", "choose": "chose", "tell": "told", "think": "thought",
        "lead": "led", "feed": "fed", "leave": "left", "spin": "spun", "shut": "shut",
        "hit": "hit", "seek": "sought", "understand": "understood", "drive": "drove",
        "hide": "hid", "unhide": "unhid", "shrink": "shrank", "sweep": "swept", "fit": "fit",
    ]

    /// Verbs that double their last letter: "drop" as "dropped".
    static let doubled = Set([
        "drop", "stop", "skip", "strip", "pin", "repin", "log", "map", "remap", "scan", "rescan",
        "grep", "plan", "ship", "tag", "retag", "wrap", "unwrap", "step", "prep", "swap", "trim",
        "commit", "recommit", "submit", "zip", "unzip", "chop", "snip", "stub", "plug", "unplug",
        "flag", "nag", "jog", "cat", "crop", "debug", "defer", "skim", "format", "reformat",
    ])

    /// Verbs that, after an and or a comma, are more often a thing named.
    /// Store, for one, was a noun in 14 of 15 such places on this Mac.
    static let mostlyNouns: Set<String> = [
        "store", "log", "diff", "index", "sample", "record", "report", "stack", "tag", "snapshot",
        "profile",
    ]

    /// A set built from an array: a literal with a word twice traps at launch.
    static let regular = doubled.union([
        "show", "rerender", "bump", "check", "recheck", "commit", "add", "readd", "create", "recreate", "list",
        "look", "fix", "remove", "rebase", "locate", "inspect", "update", "search", "push",
        "forward", "stamp", "confirm", "land", "apply", "reapply", "merge", "print", "count",
        "delete", "wire", "rewire", "survey", "compare", "measure", "remeasure", "test", "retest",
        "trace", "install", "reinstall", "uninstall", "amend", "review", "time", "render",
        "dump", "capture", "recapture", "open", "reopen", "wait", "fold", "unfold", "move",
        "retry", "try", "profile", "reprofile", "rename", "start", "restart", "click", "probe",
        "generate", "regenerate", "launch", "relaunch", "simplify", "switch", "kill", "edit",
        "pass", "extract", "crop", "carry", "export", "import", "size", "resize", "resolve",
        "extend", "register", "unregister", "stage", "unstage", "verify", "link", "unlink",
        "ask", "typecheck", "revert", "restore", "index", "reindex", "save", "finish",
        "replace", "press", "tidy", "view", "compile", "recompile", "mark", "insert", "change",
        "reduce", "gather", "point", "diff", "rediff", "refresh", "clear", "record", "bundle",
        "repeat", "use", "reuse", "document", "guard", "close", "restructure",
        "debug", "restyle", "clean", "thread", "outline", "summarize", "summarise", "exclude",
        "rank", "seed", "select", "report", "sample", "replay", "stress", "boot", "reboot",
        "scroll", "turn", "instrument", "prototype", "gate", "port", "type", "download",
        "upload", "fetch", "note", "restrict", "classify", "pick", "refine", "lengthen",
        "filter", "handle", "unlock", "lock", "rework", "relabel", "label",
        "decode", "encode", "simulate", "reconcile", "draft", "tighten", "loosen",
        "attach", "detach", "invalidate", "escape", "walk", "mirror", "aggregate", "snapshot",
        "defer", "route", "checkpoint", "accept", "raise", "animate", "squash", "combine",
        "peek", "store", "expose", "refactor", "dedupe", "erase", "toggle", "post", "hand",
        "inline", "allow", "skim", "mention", "limit", "assemble", "treat", "cover",
        "distinguish", "prefix", "name", "load", "reload", "normalize", "normalise", "realign",
        "align", "ingest", "exercise", "swap", "stack", "correct", "assert", "narrow", "orient",
        "widen", "settle", "copy", "discard", "identify", "number", "shorten", "queue", "kick",
        "explore", "examine", "describe", "explain", "summarize", "collect", "enumerate",
        "compute", "calculate", "validate", "ensure", "audit", "preview", "reproduce", "trigger",
        "invoke", "call", "watch", "tail", "parse", "format", "reformat", "lint", "query",
        "sort", "archive", "package", "sign", "notarize", "deploy", "release", "sync", "mount",
        "clone", "checkout", "patch", "prune", "enable", "disable", "confirm", "pull", "echo",
        "cat", "chmod", "touch", "count", "verify", "focus", "zoom",
    ])
}
