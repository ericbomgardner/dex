import Foundation

public struct CommandResult: Sendable {
    public let stdout: Data
    public let stderr: String
    public let exitCode: Int32
    /// Whether it was stopped for running past its timeout.
    public var timedOut = false

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

public enum ShellError: Error, Sendable, CustomStringConvertible {
    case launchFailed(command: String, underlying: String)

    public var description: String {
        switch self {
        case .launchFailed(let command, let underlying):
            "could not launch \(command): \(underlying)"
        }
    }
}

public enum Shell {

    public enum Stream: Sendable { case stdout, stderr }

    /// `environment` is added over this process's own, never in place of it.
    /// `onOutput` sees each chunk as it is read, on a background thread, and
    /// may see a chunk that ends mid-line — a build script that prints a name
    /// and then the verdict beside it on the same line holds that line open
    /// for as long as the step runs. Past `timeout` the command is terminated,
    /// then killed, and whatever it wrote by then is returned — though a
    /// grandchild still holding a pipe open can hold the return past that.
    public static func run(
        _ arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil,
        onOutput: (@Sendable (Data, Stream) -> Void)? = nil
    ) throws -> CommandResult {
        precondition(!arguments.isEmpty, "Shell.run requires at least an executable")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // waitUntilExit() spins a run loop in 50ms steps; the exit itself wakes this.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(
                command: arguments.joined(separator: " "),
                underlying: String(describing: error)
            )
        }

        let stopped = Lock(false)
        if let timeout {
            let running = UnsafeSendableBox(process)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard running.value.isRunning else { return }
                stopped.value = true
                running.value.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                    if running.value.isRunning { kill(running.value.processIdentifier, SIGKILL) }
                }
            }
        }

        let errorData = UnsafeSendableBox<Data>(Data())
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData.value = drain(errPipe, as: .stderr, onOutput: onOutput)
            group.leave()
        }

        let outputData = drain(outPipe, as: .stdout, onOutput: onOutput)
        group.wait()
        exited.wait()

        return CommandResult(
            stdout: outputData,
            stderr: String(decoding: errorData.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: process.terminationStatus,
            timedOut: stopped.value
        )
    }

    private static func drain(
        _ pipe: Pipe,
        as stream: Stream,
        onOutput: (@Sendable (Data, Stream) -> Void)?
    ) -> Data {
        let handle = pipe.fileHandleForReading
        guard let onOutput else { return handle.readDataToEndOfFile() }
        var collected = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return collected }
            collected.append(chunk)
            onOutput(chunk, stream)
        }
    }
}

private final class UnsafeSendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
