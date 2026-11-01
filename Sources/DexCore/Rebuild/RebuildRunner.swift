import Foundation

public struct RebuildRunner: Sendable {
    public let checkout: AppCheckout

    public init(checkout: AppCheckout) {
        self.checkout = checkout
    }

    public struct Result: Sendable {
        public let outcome: ActionOutcome

        public let installedBundle: String?

    }

    /// Runs the build script on the checkout as it stands; nothing here
    /// touches git. `progress` hears each phase as the script reaches it, off
    /// the main actor.
    public func build(progress: (@Sendable (String) -> Void)? = nil) -> Result {

        let spec = RebuildCommand.build(
            checkout,
            loginPath: LoginShell.path(),
            signingIdentity: LoginShell.probe(RebuildCommand.signingIdentityVariable)
        )
        let command: CommandResult
        do {
            let reader = Lock(BuildProgress.Reader())
            var onOutput: (@Sendable (Data, Shell.Stream) -> Void)?
            // Reported under the lock: the two streams drain on two threads,
            // and a phase handed on outside it could overtake a newer one.
            if let progress {
                onOutput = { data, stream in
                    reader.withLock {
                        if let phase = $0.feed(data, from: stream) { progress(phase) }
                    }
                }
            }
            command = try Shell.run(
                spec.argv,
                workingDirectory: checkout.root,
                environment: spec.environment,
                onOutput: onOutput
            )
        } catch {
            return Result(outcome: failure(String(describing: error)), installedBundle: nil)
        }

        guard command.exitCode == 0 else {
            return Result(
                outcome: failure(
                    BuildLog.failureMessage(
                        stdout: command.stdoutText,
                        stderr: command.stderr,
                        exitCode: command.exitCode
                    )
                ),
                installedBundle: nil
            )
        }

        guard let bundle = RebuildCommand.installedBundle(
            fromStdout: command.stdoutText, bundleName: checkout.bundleName
        ) else {
            return Result(
                outcome: failure("built, but \(AppCheckout.Layout.scriptPath) named no bundle to open"),
                installedBundle: nil
            )
        }

        return Result(
            outcome: ActionOutcome(
                label: Self.label,
                succeeded: true,
                message: bundle,

                successVisibleInList: true
            ),
            installedBundle: bundle
        )
    }

    public static let label = "Rebuild & Restart"

    private func failure(_ message: String) -> ActionOutcome {

        ActionOutcome(label: Self.label, succeeded: false, message: message)
    }
}
