import DexUI
import AppKit
import Network
import SwiftUI
import WebKit

/// Whether an option's preview can reach the network. A preview is model
/// output, and any request a fragment can make is a way to carry what the
/// model has read off the Mac.
/// Draws each fragment through
/// `AskPreview` itself against a listener on localhost and fails on any hit.
/// Run as `DexProbes --preview-leak-probe`.
enum PreviewLeakProbe {

    private static func fragments(_ base: String) -> [String: String] {
        [
            "img": "<img src=\"\(base)/img\">",
            "background": "<div style=\"background:url(\(base)/bg);width:9px;height:9px\"></div>",
            "refresh": "<meta http-equiv=\"refresh\" content=\"0;url=\(base)/refresh\">",
            "iframe": "<iframe src=\"\(base)/iframe\"></iframe>",
            "link": "<link rel=\"stylesheet\" href=\"\(base)/css\"><link rel=\"prefetch\" href=\"\(base)/prefetch\"><link rel=\"preload\" as=\"image\" href=\"\(base)/preload\">",
            "media": "<video poster=\"\(base)/poster\" src=\"\(base)/video\"></video><audio src=\"\(base)/audio\" autoplay></audio>",
            "object": "<object data=\"\(base)/object\"></object><embed src=\"\(base)/embed\">",
            "svg": "<svg><image href=\"\(base)/svg\"/></svg>",
            "base": "<base href=\"\(base)/base/\"><img src=\"relative\">",
            "srcset": "<picture><source srcset=\"\(base)/source\"><img src=\"data:,\"></picture><img srcset=\"\(base)/srcset 1x\">",
        ]
    }

    static func run() -> Int32 {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        let hits = Hits()
        let listener: NWListener
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        } catch {
            FileHandle.standardError.write(Data("no listener: \(error)\n".utf8))
            return 2
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .split(separator: "\r\n").first.map(String.init)
                hits.record(request ?? "a connection from \(connection.endpoint)")
                connection.cancel()
            }
        }
        let ready = Hits()
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.record("ready") }
        }
        listener.start(queue: .main)
        guard spin(until: { !ready.all.isEmpty }, limit: 5), let port = listener.port else {
            FileHandle.standardError.write(Data("listener never came up\n".utf8))
            return 2
        }

        let windows = fragments("http://127.0.0.1:\(port.rawValue)").sorted { $0.key < $1.key }.map { name, html in
            let host = NSHostingView(rootView: AskPreview(html: html).frame(width: 300, height: AskPreview.placeholder))
            let window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: AskPreview.placeholder),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            print("drew \(name)")
            return window
        }
        _ = spin(until: { false }, limit: 5)
        for window in windows { window.close() }
        listener.cancel()

        let reached = hits.all
        if reached.isEmpty {
            print("all ok: no fragment reached the listener")
            return 0
        }
        for hit in reached { print("FAIL  reached the listener: \(hit)") }
        return 1
    }

    private final class Hits: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func record(_ hit: String) { lock.withLock { list.append(hit) } }
        var all: [String] { lock.withLock { list } }
    }

    private static func spin(until done: () -> Bool, limit: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while !done(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return done()
    }
}
