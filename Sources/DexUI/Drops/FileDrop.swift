import DexCore
import AppKit
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: BundleIdentity.code, category: "drops")

/// What a drag onto the composer turns into. A file already on disk is used
/// where it lies, so a session sees its real path; an app that hands over
/// pixels instead has them stashed first, and so does one that hands over a
/// file it is only lending.
enum FileDrop {

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSImage.imageTypes.map(NSPasteboard.PasteboardType.init(rawValue:))
    }

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: fileURLsOnly)
            || imageType(on: pasteboard) != nil
    }

    static func attachments(from pasteboard: NSPasteboard) -> [ComposerAttachment] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileURLsOnly) as? [URL]
        if let urls, !urls.isEmpty {
            return urls.compactMap { kept($0.standardizedFileURL.path) }
        }

        guard let type = imageType(on: pasteboard), let data = pasteboard.data(forType: type) else {
            return []
        }

        do {
            let ext = UTType(type.rawValue)?.preferredFilenameExtension
            return [try ComposerStash.save(
                data,
                named: ComposerStash.fallbackName,
                extension: ext ?? ComposerStash.fallbackExtension
            )]
        } catch {
            logger.error("could not park the dropped image: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// What ⌘V turns into. A copied file is a path either way, but pixels win
    /// only when nothing was written: a copied table or styled paragraph carries
    /// a picture of itself beside the words, and that is not what was copied.
    static func pasted(from pasteboard: NSPasteboard) -> [ComposerAttachment] {
        guard pasteboard.canReadObject(forClasses: [NSURL.self], options: fileURLsOnly)
                || pasteboard.string(forType: .string) == nil
        else { return [] }
        return attachments(from: pasteboard)
    }

    /// A copy that fails falls back to the path it was handed, but only while
    /// there is still something there. The likeliest reason it failed is that the
    /// lender already took the file back, and nothing downstream re-checks: a chip
    /// standing on a dead path is the very failure this exists to stop, arriving
    /// silently a turn later. No chip says so at the drop, where it can be redone.
    private static func kept(_ path: String) -> ComposerAttachment? {
        guard ComposerStash.isBorrowed(path) else { return ComposerAttachment(path: path) }
        do {
            return try ComposerStash.keep(path)
        } catch {
            logger.error("could not keep the borrowed drop: \(String(describing: error), privacy: .public)")
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return ComposerAttachment(path: path)
        }
    }

    private static var fileURLsOnly: [NSPasteboard.ReadingOptionKey: Any] {
        [.urlReadingFileURLsOnly: true]
    }

    /// A drag carries several flavours of the same image; the first one that names a
    /// file extension is the one worth writing out.
    private static func imageType(on pasteboard: NSPasteboard) -> NSPasteboard.PasteboardType? {
        pasteboard.types?.first { type in
            guard let utType = UTType(type.rawValue) else { return false }
            return utType.conforms(to: .image) && utType.preferredFilenameExtension != nil
        }
    }
}
