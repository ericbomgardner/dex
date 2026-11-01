import DexCore
import AppKit
import Observation

/// Rebuilds the checkout this bundle was built from and restarts into it.
/// Only present when the app is running out of a `.build` directory.
@MainActor
@Observable
final class Rebuilder {
    let checkout: AppCheckout?

    /// The commit the bundle came out of, not the one the checkout is on now.
    let runningBuild: RunningBuild?

    private(set) var isRunning = false

    /// What the build script is doing right now, off its own output, so a
    /// ten-minute probe run reads as one rather than as a hang. Nil between
    /// builds and until the script says anything.
    private(set) var progress: String?

    /// Set by the store, so a build lands in the same toast as everything else.
    var onOutcome: ((ActionOutcome?) -> Void)?

    init(
        bundlePath: String = Bundle.main.bundlePath,
        buildCommit: String? = AppCheckout.buildCommit { Bundle.main.object(forInfoDictionaryKey: $0) }
    ) {
        checkout = AppCheckout.resolve(bundlePath: bundlePath)
        runningBuild = checkout?.runningBuild(infoValue: buildCommit)
    }

    /// Builds and opens the new bundle. The host is left to the app's own idle
    /// auto-replace, so a turn in flight is never ended here.
    func rebuildAndRestart() {
        guard let checkout, !isRunning else { return }
        isRunning = true
        progress = nil
        onOutcome?(nil)

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let runner = RebuildRunner(checkout: checkout)
                let report: @Sendable (String) -> Void = { phase in
                    // A serial queue, so phases land in the order they were read.
                    DispatchQueue.main.async { self.progress = phase }
                }
                return runner.build(progress: report)
            }.value
            self.isRunning = false
            self.progress = nil

            guard let bundle = result.installedBundle else {
                self.onOutcome?(result.outcome)
                return
            }

            do {
                try self.spawnRelaunch(bundlePath: bundle)
            } catch {

                self.onOutcome?(ActionOutcome(
                    label: RebuildRunner.label,
                    succeeded: false,
                    message: "built \(bundle), but could not schedule the relaunch: \(error)"
                ))
                return
            }

            NSApp.terminate(nil)
        }
    }

    private func spawnRelaunch(bundlePath: String) throws {
        let spec = RebuildCommand.relaunch(afterPID: ProcessInfo.processInfo.processIdentifier,
                                           bundlePath: bundlePath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments

        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
