import Foundation

public enum ComposerDraft {

    public static func persistable(_ text: String) -> String? {
        isBlank(text) ? nil : text
    }

    public static func restored(_ stored: String?) -> String {
        guard let stored, !isBlank(stored) else { return "" }
        return stored
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
