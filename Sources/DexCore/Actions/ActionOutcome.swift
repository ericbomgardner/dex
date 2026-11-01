import Foundation

public struct ActionOutcome: Sendable, Hashable {
    public let label: String
    public let succeeded: Bool
    public let message: String

    public let isReadout: Bool

    public let successVisibleInList: Bool

    public let successMessageRestatesLabel: Bool

    public init(
        label: String,
        succeeded: Bool,
        message: String,
        isReadout: Bool = false,
        successVisibleInList: Bool = false,
        successMessageRestatesLabel: Bool = false
    ) {
        self.label = label
        self.succeeded = succeeded
        self.message = message
        self.isReadout = isReadout
        self.successVisibleInList = successVisibleInList
        self.successMessageRestatesLabel = successMessageRestatesLabel
    }

    public var shouldBeShown: Bool {
        !succeeded || !successVisibleInList
    }

    public var headline: String {
        let firstLine = message
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return firstLine.isEmpty ? (succeeded ? "done" : "failed") : firstLine
    }

    public var detail: String? {
        succeeded && successMessageRestatesLabel ? nil : headline
    }

    public static let successDwell: TimeInterval = 4

    public var dwell: TimeInterval? {
        succeeded && !isReadout ? Self.successDwell : nil
    }
}
