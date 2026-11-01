import DexCore
import Foundation

@MainActor
final class TranscriptWatcher {

    private struct Watch {
        let url: URL
        let source: any DispatchSourceFileSystemObject
    }

    private var watches: [String: Watch] = [:]
    private let debounce = Debounce()

    private let locator: TranscriptLocator

    /// The file as well as the row: what was written is worth reading, and the
    /// watch is the one place that already knows where it is.
    private let onActivity: (String, Date, URL) -> Void

    init(
        locator: TranscriptLocator = TranscriptLocator(),
        onActivity: @escaping (String, Date, URL) -> Void
    ) {
        self.locator = locator
        self.onActivity = onActivity
    }

    func sync(rows: [SessionRowModel]) {
        let live = rows.filter(\.session.isLive)
        var wanted: [String: URL] = [:]
        for row in live {
            guard let url = locator.locate(sessionID: row.session.sessionId)
            else { continue }
            wanted[row.rowID] = url
        }

        for (rowID, watch) in watches where wanted[rowID] != watch.url {
            watch.source.cancel()
            watches[rowID] = nil
            debounce.cancel(rowID)
        }

        for (rowID, url) in wanted where watches[rowID] == nil {
            watch(rowID: rowID, url: url)
        }
    }

    func stop() {
        debounce.cancelAll()
        for watch in watches.values { watch.source.cancel() }
        watches.removeAll()
    }

    private func watch(rowID: String, url: URL) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = source.data
            if mask.contains(.delete) || mask.contains(.rename) {

                self.watches[rowID]?.source.cancel()
                self.watches[rowID] = nil
                return
            }
            self.scheduleActivity(rowID: rowID, url: url)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watches[rowID] = Watch(url: url, source: source)
    }

    private func scheduleActivity(rowID: String, url: URL) {
        debounce(rowID) { [weak self] in self?.onActivity(rowID, Date(), url) }
    }
}
