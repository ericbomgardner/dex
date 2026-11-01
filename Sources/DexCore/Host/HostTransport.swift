import Foundation

/// Called on the client's queue and calls back on it, never after `close()`.
protocol HostTransport: AnyObject, Sendable {
    func open(
        on queue: DispatchQueue,
        onRead: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (Bool) -> Void
    )
    func write(_ bytes: Data)
    func close()
}

final class UnixSocketTransport: HostTransport, @unchecked Sendable {
    private let path: String
    private var descriptor: Int32 = -1
    private var reader: (any DispatchSourceRead)?
    private var queue: DispatchQueue?
    private var onClose: (@Sendable (String) -> Void)?
    private var writeFailed = false

    init(path: String) {
        self.path = path
    }

    func open(
        on queue: DispatchQueue,
        onRead: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard let fd = openSocket() else { return completion(false) }
        descriptor = fd
        self.queue = queue
        self.onClose = onClose
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable(onRead: onRead, onClose: onClose) }
        source.setCancelHandler { Darwin.close(fd) }
        reader = source
        source.resume()
        completion(true)
    }

    func write(_ bytes: Data) {
        guard descriptor >= 0, !writeFailed else { return }
        let finished = bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: sent),
                    buffer.count - sent
                )
                if written > 0 {
                    sent += written
                    continue
                }
                if errno == EINTR { continue }
                return false
            }
            return true
        }
        guard !finished else { return }
        // Told on the next turn of the queue, so the client isn't torn down inside its own write.
        writeFailed = true
        queue?.async { [weak self] in
            guard let self, reader != nil, let onClose else { return }
            onClose("writing to the host failed")
        }
    }

    func close() {
        reader?.cancel()
        reader = nil
        descriptor = -1
        onClose = nil
    }

    private func openSocket() -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return nil }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { destination in
            path.withCString { source in
                strncpy(
                    UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self),
                    source,
                    capacity - 1
                )
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return nil
        }

        // SIGPIPE would take the whole app down when the host exits mid-write.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func readAvailable(
        onRead: @Sendable (Data) -> Void,
        onClose: @Sendable (String) -> Void
    ) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = chunk.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        }

        if count > 0 {
            onRead(Data(chunk[0..<count]))
            return
        }
        if count < 0 && errno == EINTR { return }
        onClose(count == 0 ? "the host closed the connection" : "the connection failed")
    }
}
