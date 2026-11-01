import Foundation

/// How a picker draws the row nothing has been picked on.
///
/// Closed, it names what the next session will actually run at and stops. The
/// word "Default" there is the app declining to say what it is about to do,
/// which is what these rows were given a resolved value for in the first place
/// — and the label is already drawn in grey when nothing was picked, so the
/// word was spending the composer's widest line to repeat the colour. Open,
/// there is room for both, so the row names the value and marks it as the one
/// Default lands on.
///
/// Callers hold the nil case themselves, and it is real rather than rare: a
/// cascade that sets `effortLevel` in no file resolves to nothing, and a model
/// has no name until the CLI has been asked for one. Both fall back to the bare
/// word there rather than naming a value no file asked for.
public enum DefaultLabel {

    public static func text(for resolved: String, open: Bool) -> String {
        open ? "\(resolved) (Default)" : resolved
    }
}
