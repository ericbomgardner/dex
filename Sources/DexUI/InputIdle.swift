import CoreGraphics
import Foundation

/// How long the pointer and keyboard have been still, off the window server.
enum InputIdle {

    /// The kinds of input that count as someone being here. Listed rather than
    /// asked as "any event": `CGEventType` has no case for the any-event
    /// constant, and a nil there would read as idle forever.
    private static let kinds: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged,
        .keyDown, .scrollWheel,
    ]

    static func seconds() -> TimeInterval {
        kinds.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
    }
}
