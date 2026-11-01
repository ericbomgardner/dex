import Foundation

public enum Activity: Hashable, Sendable {

    case active

    case quiet

    case unknown

    public var isQuiet: Bool { self == .quiet }
}

public enum ActivitySignal {

    public static let quietAfter: TimeInterval = 15

    public static func resolve(
        state: HostSessionState,
        lastTranscriptWrite: Date?,
        now: Date = Date()
    ) -> Activity {
        switch state {
        case .starting, .running, .compacting, .unknown:

            return .active

        case .idle, .done, .failed:

            guard let lastTranscriptWrite else { return .unknown }
            let age = now.timeIntervalSince(lastTranscriptWrite)

            guard age >= 0 else { return .unknown }
            return age >= quietAfter ? .quiet : .active

        case .asking:

            return .unknown
        }
    }
}
