import Foundation

/// A command's description said as what is happening now, while it runs: the
/// model writes "Run the tests", the running row says "Running the tests".
/// Turns the same words `PastTense` does, off the same lists.
enum Ongoing {

    static func of(_ clause: String) -> String {
        PastTense.turning(clause, with: form)
    }

    /// Verbs past tense leaves alone that still double before -ing: "run" as "running".
    static let doubled: Set<String> = [
        "run", "rerun", "get", "set", "reset", "quit", "split", "put", "let", "cut", "begin",
        "spin", "shut", "hit", "fit",
    ]

    static func form(_ verb: String) -> String? {
        guard PastTense.regular.contains(verb) || PastTense.irregular[verb] != nil else { return nil }
        if PastTense.doubled.contains(verb) || doubled.contains(verb) { return verb + String(verb.last!) + "ing" }
        if verb.hasSuffix("ie") { return verb.dropLast(2) + "ying" }
        if verb.hasSuffix("e"), !verb.hasSuffix("ee"), !verb.hasSuffix("ye"), !verb.hasSuffix("oe"), verb.count > 2 {
            return verb.dropLast() + "ing"
        }
        return verb + "ing"
    }
}
