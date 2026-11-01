import Foundation

/// What `make-app.sh` is doing right now, read off what it prints.
///
/// A plain rebuild is a minute of `swift build` and a copy. An SDK update is
/// that plus an `npm install` and, when the pin moved, `recheck.sh` — every
/// probe against the new CLI, a dozen real sessions, ten minutes — behind a
/// toast that used to say only "Rebuild & Restart". The question that raised
/// this was "is the rebuild hung?", and the answer was in the script's own
/// output the whole time. This reads it as it streams.
///
/// Only lines the script prints for this purpose count; `swift build`'s own
/// progress is folded to one word. `recheck.sh` prints a probe's name before
/// it runs and the verdict on the same line after, so the line that says which
/// probe is running is a *partial* one, and `Reader` keeps the unfinished
/// tail of each stream to read it.
public enum BuildProgress {

    /// The phrase for one line, or nil for a line that says nothing new.
    public static func phase(of rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        if let probe = line.firstMatch(of: /^(\d+)\/(\d+) (\S+)/) {
            return "probe \(probe.1) of \(probe.2): \(probe.3)"
        }
        if let sdk = line.firstMatch(of: /^==> SDK (\S+) → (\S+)/) {
            return "SDK \(sdk.1) → \(sdk.2)"
        }
        if (line.hasPrefix("[") && line.contains("] Compiling")) || line.hasPrefix("Compiling") {
            return "compiling…"
        }
        if line.hasPrefix("Installing Sidecar dependencies") { return "installing the Sidecar…" }
        if line.hasPrefix("Updating the Sidecar SDK") { return "asking npm for the newest SDK…" }
        if line.hasPrefix("Re-running the probes") { return "re-running the probes…" }
        if line.hasPrefix("swift test against") { return "swift test against the rewritten lists…" }
        if line.hasPrefix("==> fetching node") { return "fetching node for the host…" }
        if line.hasPrefix("==> bundling") { return "bundling the app…" }
        return nil
    }

    /// Feeds chunks as they arrive and answers with the newest phase seen.
    /// The partial line is read every time a chunk lands on it, since a probe's
    /// name sits on one for as long as the probe runs.
    public struct Reader: Sendable {
        private var partial: [Shell.Stream: String] = [:]

        public init() {}

        public mutating func feed(_ data: Data, from stream: Shell.Stream) -> String? {
            let text = (partial[stream] ?? "") + String(decoding: data, as: UTF8.self)
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            partial[stream] = lines.removeLast()
            var newest: String?
            for line in lines + [partial[stream] ?? ""] {
                if let phase = BuildProgress.phase(of: line) { newest = phase }
            }
            return newest
        }
    }
}
