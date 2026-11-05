import Foundation
import os

/// The app's end of the socket: connects, spawns the host if nobody is holding
/// it, and reconnects when it goes away.
///
/// Everything here runs on one serial queue, and events are handed to the owner
/// on a queue it chooses, so the caller never has to think about which thread a
/// read landed on.
public final class HostClient: @unchecked Sendable {

    public enum Status: Sendable, Equatable {
        case idle
        case connecting
        case connected(host: String, sdk: String)
        case unavailable(String)
    }

    private var location: HostLocation
    private let queue = DispatchQueue(label: BundleIdentity.code + ".host")
    private let delivery: DispatchQueue
    private let onEvent: @Sendable (HostEvent) -> Void
    private let onStatus: @Sendable (Status) -> Void

    private var transport: (any HostTransport)?
    private var opening: (any HostTransport)?
    private var framing = HostFraming()
    private var waiting: [String: Waiter] = [:]
    private var queued: [Data] = []
    private var status: Status = .idle
    private var stopped = false
    private var attempt = 0
    private var counter = 0
    /// One per host this process spawned and has not yet buried. A child that
    /// exits unwaited stays a zombie, and every automatic replace leaves one.
    private var reapers: [pid_t: any DispatchSourceProcess] = [:]

    /// The error a waited-on request is answered with when the socket goes
    /// first. Not a refusal: the host may well have acted on it.
    public static let droppedError = "the connection to the host dropped"

    /// Long enough to cover a cold `node` start, short enough that a host that
    /// will never come up is reported rather than retried forever.
    private static let attempts = 12
    private static let retryDelay = DispatchTimeInterval.milliseconds(400)
    /// How long a host that never came up is left alone before trying again.
    private static let patience = DispatchTimeInterval.seconds(20)

    public init(
        location: HostLocation,
        delivery: DispatchQueue = .main,
        onStatus: @escaping @Sendable (Status) -> Void = { _ in },
        onEvent: @escaping @Sendable (HostEvent) -> Void
    ) {
        self.location = location
        self.delivery = delivery
        self.onStatus = onStatus
        self.onEvent = onEvent
    }

    /// A reply's handler, and whether losing the connection is an answer.
    ///
    /// The two differ on purpose. A fire-and-forget send whose reply never
    /// arrives is a refusal nobody asked about; an awaited one that never
    /// arrives is a caller suspended for good.
    private struct Waiter {
        let handler: @Sendable (HostReply) -> Void
        let answeredByADrop: Bool
    }

    deinit {
        opening?.close()
        transport?.close()
    }

    // MARK: - Lifecycle

    public func start() {
        queue.async { [self] in
            stopped = false
            attempt = 0
            connect(spawningIfAbsent: true)
        }
    }

    public func stop() {
        queue.async { [self] in
            stopped = true
            teardown()
            publish(.idle)
        }
    }

    public func nextRequestID() -> String {
        queue.sync { nextRequestIDOnQueue() }
    }

    /// The same counter for callers already running on `queue`; going through
    /// the public one from there is a `dispatch_sync` onto the current queue,
    /// which traps rather than deadlocking.
    private func nextRequestIDOnQueue() -> String {
        counter += 1
        return "r\(counter)"
    }

    // MARK: - Sending

    public func send(_ request: HostRequest) {
        send(request, reply: nil)
    }

    public func send(
        _ request: HostRequest,
        reply: (@Sendable (HostReply) -> Void)?
    ) {
        queue.async { [self] in
            guard let line = try? request.line() else { return }
            if let reply {
                waiting[request.id] = Waiter(handler: reply, answeredByADrop: false)
            }
            write(line)
        }
    }

    /// The same send, waited on. A connection that drops answers rather than
    /// leaving the caller suspended, since the reply it was waiting for died
    /// with the socket.
    public func reply(to request: HostRequest) async -> HostReply {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let line = try? request.line() else {
                    return continuation.resume(
                        returning: HostReply(
                            id: request.id, ok: false, key: nil,
                            error: "the request could not be written"
                        )
                    )
                }
                waiting[request.id] = Waiter(
                    handler: { continuation.resume(returning: $0) },
                    answeredByADrop: true
                )
                write(line)
            }
        }
    }

    public func reply(to make: (String) -> HostRequest) async -> HostReply {
        await reply(to: make(nextRequestID()))
    }

    private func write(_ line: Data) {
        guard let transport else {
            // Held rather than dropped: a message typed while the host is still
            // coming up should arrive, not vanish.
            queued.append(line)
            return
        }
        transport.write(line)
    }

    // MARK: - Connecting

    private func connect(spawningIfAbsent spawn: Bool) {
        guard !stopped else { return }
        publish(.connecting)
        open(UnixSocketTransport(path: location.socket), spawningIfAbsent: spawn)
    }

    private func open(_ next: any HostTransport, spawningIfAbsent spawn: Bool) {
        opening = next
        next.open(
            on: queue,
            onRead: { [weak self] chunk in self?.received(chunk) },
            onClose: { [weak self] reason in self?.dropped(reason) },
            completion: { [weak self] opened in
                self?.finishConnecting(next, opened: opened, spawningIfAbsent: spawn)
            }
        )
    }

    private func finishConnecting(
        _ next: any HostTransport, opened: Bool, spawningIfAbsent spawn: Bool
    ) {
        guard opening === next, !stopped else { return next.close() }
        opening = nil

        if opened {
            transport = next
            framing.reset()
            attempt = 0
            let held = queued
            queued = []
            let hello = try? HostRequest.hello(
                id: nextRequestIDOnQueue(), launches: true
            ).line()
            for line in held { write(line) }
            if let hello { write(hello) }
            return
        }

        if spawn, attempt == 0 {
            spawnHost()
        }

        attempt += 1
        if attempt < Self.attempts { retry(after: Self.retryDelay) } else { waitOutHost() }
    }

    private func retry(after delay: DispatchTimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            connect(spawningIfAbsent: false)
        }
    }

    private func waitOutHost() {
        publish(.unavailable("the host did not come up"))
        // Said so, then kept trying more slowly. `start()` is called once at
        // launch, so giving up for good would leave a host that came up a
        // second late unreachable until the app restarted.
        queue.asyncAfter(deadline: .now() + Self.patience) { [self] in
            guard !stopped, transport == nil, opening == nil else { return }
            attempt = 0
            connect(spawningIfAbsent: true)
        }
    }

    private func received(_ chunk: Data) {
        for line in framing.consume(chunk) { deliver(line) }
        if framing.overflowed { dropped("the host sent a line too long to read") }
    }

    private static let logger = Logger(subsystem: BundleIdentity.code, category: "host")

    private func deliver(_ line: Data) {
        let event: HostEvent
        do {
            event = try JSONDecoder().decode(HostEvent.self, from: line)
        } catch {
            Self.logger.error("a \(Self.eventType(of: line), privacy: .public) line from the host (\(line.count) bytes) would not decode: \(String(describing: error), privacy: .public)")
            return
        }

        switch event {
        case .reply(let reply):
            if let waiter = waiting.removeValue(forKey: reply.id) {
                delivery.async { waiter.handler(reply) }
            }
        case .welcome(let welcome):
            publish(.connected(host: welcome.host, sdk: welcome.sdk))
        default:
            break
        }

        delivery.async { [onEvent] in onEvent(event) }
    }

    /// All that is logged of a line that would not decode, beside its length:
    /// none of its content, since it may carry someone's message.
    static func eventType(of line: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        return object?["type"] as? String ?? "untyped"
    }

    private func dropped(_ reason: String) {
        teardown()
        guard !stopped else { return }
        publish(.unavailable(reason))
        // Reconnects to whatever is holding the socket now; sessions belong to
        // the host, so a dropped connection loses the view of them, not them.
        queue.asyncAfter(deadline: .now() + .milliseconds(600)) { [self] in
            attempt = 0
            connect(spawningIfAbsent: true)
        }
    }

    private func teardown() {
        opening?.close()
        opening = nil
        transport?.close()
        transport = nil
        framing.reset()
        let orphaned = waiting.filter { $0.value.answeredByADrop }
        waiting.removeAll()
        for (id, waiter) in orphaned {
            let reply = HostReply(
                id: id, ok: false, key: nil, error: Self.droppedError
            )
            delivery.async { waiter.handler(reply) }
        }
    }

    private func publish(_ next: Status) {
        guard status != next else { return }
        status = next
        delivery.async { [onStatus] in onStatus(next) }
    }

    // MARK: - Spawning

    /// Started without being waited on. macOS re-parents an orphan to launchd
    /// rather than signalling it, so the host keeps its sessions when the app
    /// quits — which is the whole reason it is a separate process.
    ///
    /// Spawned disclaimed, so that the host is responsible for itself. A child
    /// normally answers to its parent for permissions, and the parent here is
    /// gone within hours; a screen recording or accessibility request made by a
    /// session after that was attributed to whatever tccd could still name.
    /// `posix_spawn` rather than `Process`, because that attribute has no
    /// other door. The CLOEXEC default is what `Process` set too — the host
    /// must not inherit the app's socket.
    private func spawnHost() {
        spawnLocalHost(node: location.node, entry: location.entry)
    }

    /// The login PATH rather than launchd's, because the host's sessions start
    /// stdio MCP servers by bare name (`npx`, `uvx`) from that environment.
    static func hostEnvironment(
        for location: HostLocation,
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        loginPath: String?
    ) -> [String: String] {
        var environment = inherited
        if let loginPath { environment["PATH"] = loginPath }
        environment["DEX_HOST_SOCKET"] = location.socket
        return environment
    }

    private func spawnLocalHost(node: String, entry: String) {
        let environment = Self.hostEnvironment(for: location, loginPath: LoginShell.path())
        let directory = URL(fileURLWithPath: entry)
            .deletingLastPathComponent().path

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        Self.disclaimResponsibility(&attributes)

        let argv = Self.cStrings([node, entry])
        let envp = Self.cStrings(environment.map { "\($0.key)=\($0.value)" })
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        guard posix_spawn(&pid, node, &actions, &attributes, argv, envp) == 0 else { return }
        reap(pid)
    }

    /// Waits for the host without blocking on it: the exit is watched, and the
    /// child is collected the moment it goes. Nothing about the host being
    /// detached changes this — it is still this process's child until then.
    /// A host that dies before the watch is on — node refusing to start — is
    /// caught by the look taken right after, since a watch put on a process
    /// already gone may never fire.
    private func reap(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: queue
        )
        source.setEventHandler { [weak self] in self?.collect(pid) }
        reapers[pid] = source
        source.activate()
        collect(pid)
    }

    private func collect(_ pid: pid_t) {
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        reapers.removeValue(forKey: pid)?.cancel()
    }

    private static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }

    private typealias SetDisclaim = @convention(c) (
        UnsafeMutablePointer<posix_spawnattr_t?>, Int32
    ) -> Int32

    /// `responsibility_spawnattrs_setdisclaim` is in libsystem and in no
    /// header, so it is looked up by name; missing, the host answers to the
    /// app as before.
    private static func disclaimResponsibility(_ attributes: inout posix_spawnattr_t?) {
        guard
            let symbol = dlsym(
                UnsafeMutableRawPointer(bitPattern: -2),
                "responsibility_spawnattrs_setdisclaim"
            )
        else { return }
        _ = unsafeBitCast(symbol, to: SetDisclaim.self)(&attributes, 1)
    }
}
