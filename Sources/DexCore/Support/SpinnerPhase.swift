import Foundation

public enum SpinnerPhase {

    public static let period: TimeInterval = 1

    public static func turns(at date: Date, period: TimeInterval = period) -> Double {
        guard period > 0 else { return 0 }
        let elapsed = date.timeIntervalSinceReferenceDate / period
        return elapsed - elapsed.rounded(.down)
    }
}
