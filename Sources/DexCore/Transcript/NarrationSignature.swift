import Foundation

/// What kind of block the server said a `thinking` block is, read out of the
/// signature that rides beside it.
///
/// Two kinds reach a transcript. `thinking` is the model's own reasoning,
/// summarised. **`narration` is not reasoning at all** — the CLI's own schema
/// calls it a "server summary of the prose between tool calls", which is to say
/// it is the assistant *talking to you*, folded into a block the pane used to
/// draw as a collapsed Thought. A turn that narrates and then asks a question
/// puts the whole setup for that question behind a disclosure triangle, and the
/// question arrives making no sense. Terminal Claude Code draws these as speech.
///
/// The CLI hands the same reading to its own renderer as `narration_block_indexes`
/// on the assistant frame, explicitly so a renderer needn't decode this envelope.
/// **That field is on the SDK stream and never in the file**, and the pane is
/// built from the file so that archived and resumed rows answer too — so the
/// envelope is where this has to be read from. It is the reason `SignatureProbe`
/// exists: nothing else would notice the format moving.
///
/// **Fail closed, the same way the CLI does.** Anything unparseable — a legacy
/// signature, a format that has moved on — reads as ordinary thinking, which is
/// what every block read as before this existed. Opus 4.6 and most of 4.7 land
/// there today.
public enum NarrationSignature {

    /// The tag the server puts on prose it summarised, as opposed to reasoning.
    static let narration = "narration"

    /// Whether this block is the assistant speaking rather than thinking.
    public static func isNarration(_ signature: String?) -> Bool {
        guard let signature else { return false }
        return blockKind(of: signature) == narration
    }

    /// `block_kind` off the signature envelope: base64 → field 2 → field 1 →
    /// string field 8. The path and the fail-closed walk below are ported from
    /// the CLI's own decoder rather than guessed at.
    public static func blockKind(of signature: String) -> String? {
        guard let bytes = decodeBase64(signature) else { return nil }
        guard let envelope = bytes.field(2), let inner = envelope.field(1),
              let kind = inner.field(8)
        else { return nil }
        return String(bytes: kind, encoding: .utf8)
    }

    /// Signatures arrive padded, but a decoder that rejects an unpadded one
    /// would fail closed on a block that really is narration — a silent revert
    /// to the bug this exists to fix, rather than the safe kind of failure.
    private static func decodeBase64(_ signature: String) -> [UInt8]? {
        if let exact = Data(base64Encoded: signature) { return [UInt8](exact) }
        let short = signature.count % 4
        guard short != 0 else { return nil }
        let padded = signature + String(repeating: "=", count: 4 - short)
        return Data(base64Encoded: padded).map { [UInt8]($0) }
    }
}

extension Collection where Element == UInt8, Index == Int {

    /// The last length-delimited field with this number, or nil if the bytes
    /// aren't a protobuf message at all. Last rather than first because that is
    /// what the CLI's walk settles on, and a repeated field would otherwise be
    /// read differently here than there.
    fileprivate func field(_ wanted: Int) -> ArraySlice<UInt8>? {
        var found: ArraySlice<UInt8>?
        var at = startIndex

        while at < endIndex {
            guard let tag = varint(at: at) else { return nil }
            let wire = tag.value & 7
            let number = tag.value >> 3
            at = tag.next

            switch wire {
            case 0:
                guard let skipped = varint(at: at) else { return nil }
                at = skipped.next
            case 1:
                guard at + 8 <= endIndex else { return nil }
                at += 8
            case 2:
                guard let length = varint(at: at),
                      length.value <= UInt64(endIndex - length.next)
                else { return nil }
                let end = length.next + Int(length.value)
                if number == UInt64(wanted) {
                    found = ArraySlice(self[length.next..<end])
                }
                at = end
            case 5:
                guard at + 4 <= endIndex else { return nil }
                at += 4
            default:
                return nil
            }
        }

        return found
    }

    /// A base-128 varint, capped at the 10 bytes the wire format allows.
    private func varint(at start: Int) -> (value: UInt64, next: Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0

        for step in 0..<10 {
            let at = start + step
            guard at < endIndex else { return nil }
            let byte = self[at]
            value |= UInt64(byte & 127) << shift
            if byte & 128 == 0 { return (value, at + 1) }
            shift += 7
        }

        return nil
    }
}
