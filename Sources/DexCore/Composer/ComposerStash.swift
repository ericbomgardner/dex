import Foundation

/// An image dragged out of a browser or Preview arrives as pixels with no path to
/// point a session at, so it is written to the temporary directory first. macOS
/// clears that out on its own schedule, which is far longer than the seconds it
/// takes the dispatched session to read the file.
public enum ComposerStash {

    public static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Dex/dropped", isDirectory: true)
    }

    /// Each drop gets its own folder, so uniqueness costs the file no readability.
    public static func save(
        _ data: Data,
        named name: String,
        extension ext: String
    ) throws -> ComposerAttachment {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let file = folder
            .appendingPathComponent(basename(from: name))
            .appendingPathExtension(ext)
        try data.write(to: file)

        return ComposerAttachment(path: file.path)
    }

    /// A drag out of the system's scratch space hands over a file the sending app
    /// still owns. macOS's screenshot thumbnail is the one that bites: the file it
    /// drags from is moved to the save location the moment the thumbnail dismisses,
    /// and the session reads the path a queued message and a tool call later, by
    /// which time there is nothing there. The drop is the one moment the file is
    /// certain to exist, since the drop is what it came from.
    public static func isBorrowed(
        _ path: String,
        temporaryDirectory: String = NSTemporaryDirectory()
    ) -> Bool {
        let resolved = resolve(path)
        guard !resolved.hasPrefix(folderPrefix(resolve(directory.path))) else { return false }
        return [temporaryDirectory, "/var/folders"]
            .map { folderPrefix(resolve($0)) }
            .contains { resolved.hasPrefix($0) }
    }

    /// Takes a copy of a borrowed file, keeping its name so the chip and the
    /// session both still read as the thing that was dropped.
    ///
    /// Copying on the main thread is safe to do here even though the same thumbnail
    /// that lends a screenshot lends a screen recording: the stash is on the same
    /// APFS volume as the scratch space, so this clones rather than copies, and
    /// 512MB measured 0ms. Moving it off the main thread would buy nothing and cost
    /// the guarantee the copy finishes before the lender takes the file back.
    public static func keep(_ path: String) throws -> ComposerAttachment {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            let file = folder.appendingPathComponent(plainly(filename(from: path)))
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: file)
            return ComposerAttachment(path: file.path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Stands a cleanly named symlink in front of a file that is staying where it
    /// lies. macOS names a screenshot with a narrow no-break space before the
    /// AM/PM, and that character survives every hop but the one that counts: a
    /// session retyping the path into a shell command types an ordinary space and
    /// is told `No such file or directory` about a file sitting right there. Read
    /// tolerates the mistype and Bash does not, so it arrives as a file that was
    /// never delivered rather than as a name that could be asked about again.
    ///
    /// A link rather than a copy: the file is the reader's own and may be large,
    /// and pointing at it keeps the two in step. A source that moves leaves the
    /// link dangling, which `ComposerAttachments.present` already reads as gone.
    ///
    /// A missing source is refused rather than linked. POSIX is happy to point a
    /// link at nothing, and a dangling one would hand a session a path with the
    /// name it was dropped under nowhere in it.
    public static func link(_ path: String) throws -> ComposerAttachment {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            let link = folder.appendingPathComponent(plainly(filename(from: path)))
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: URL(fileURLWithPath: path)
            )
            return ComposerAttachment(path: link.path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Whether a path reaches a session as the path it will be typed back as.
    /// Asked of the whole path rather than of the name, since a folder can carry
    /// the character just as a file can.
    public static func typesAsWritten(_ path: String) -> Bool {
        plainly(path) == path
    }

    /// Exotic spaces become ordinary ones and the invisibles go: a name nobody
    /// can tell from a plain one is better off being the plain one.
    static func plainly(_ name: String) -> String {
        String(name.map { spaces.contains($0) ? " " : $0 }.filter { !invisibles.contains($0) })
    }

    private static let spaces: Set<Character> = [
        "\u{00A0}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}",
        "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}",
        "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}",
    ]

    private static let invisibles: Set<Character> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}",
    ]

    public static let fallbackName = "image"
    public static let fallbackExtension = "png"

    static func basename(from name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty else { return fallbackName }
        return plainly(stem.replacingOccurrences(of: "/", with: "-"))
    }

    static func filename(from path: String) -> String {
        let name = URL(fileURLWithPath: path).standardizedFileURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            return "\(fallbackName).\(fallbackExtension)"
        }
        return name
    }

    /// `/var` is a symlink to `/private/var`, so the same directory reaches here
    /// spelled two ways and a prefix test on the raw path misses one of them.
    /// Resolving alone doesn't settle it: Foundation puts `/private` on a path
    /// that exists and takes it off one that doesn't, and the file being asked
    /// about here is on its way out. So the prefix comes off both sides.
    private static func resolve(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix("/private/") else { return resolved }
        return String(resolved.dropFirst("/private".count))
    }

    private static func folderPrefix(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}
