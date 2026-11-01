import XCTest
@testable import DexCore

/// Synthetic signatures built field for field in the layout real ones have:
/// a version, the envelope in field 2 with its header in field 1, the kind in
/// the header's field 8 among the other header fields, then the opaque
/// digests. The model string is a made-up one; real signatures stay out of
/// the repo.
final class NarrationSignatureTests: XCTestCase {

    /// Prose the server summarised — the assistant speaking.
    private let narrationWithText = "CAISugMKjAEIERgCKkA7Qd0QNEq8/JZfULb0i/RAM1HIGcFTrg2/oHNhgd+X5CTwZvFJIVjhQ+KvAdLbWPmV/WY0JO16q6/MxyySufmbMhFjbGF1ZGUtdGVzdC1tb2RlbDgBQgluYXJyYXRpb25aJDAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwMDAwMRIMsMtv01//m/qG8pDaGgySi2yEkqFZyDV1vOciMHsXkUffosO2VCBYuaqDljGiBj6AWQHSGfA448iWRlHvd5m51OnwGQkmngnUr5I74CraAVve79KY6yNu8fdXLqRpa0OYU+DRl/NKFKd2fIxWbuwyevWuR2/ifeG+xAf3mEZweh/8IvjL0ZJu2aurIn76q04P9kKx+FX6eeQsgjU3dTwS1FZW+PBGRYDqaVpURiMCXgGfFH4DLxMqtX0wJrhDmxtv2/zP3pIf2rrmJpK55lkvx6tyipGkm3T+gzpRlwSNcZZ48jyzINIYP00oYJYtYlmCxkGkzlWeaw7Hha4+RPx5CdL6lAL3KxMCtrpBxVFKfJHoaNzRJgXuvRo8RNlvDLfKEQkpj9y+5mhgGAE="

    /// Tagged narration with no text behind it. The CLI's rule is
    /// that these get ordinary thinking treatment, which the document does by
    /// dropping every empty thinking block before it ever asks the kind.
    private let narrationWithoutText = "CAISmAIKjAEIEBgCKkB4dbYHQVjJ4YDD/g1+cruBFrK20Pomlk9xUj61q0CpENiIrkb6/DWtoINd9VEgkgQgUTDzapMgqGlLOH8pp9X0MhFjbGF1ZGUtdGVzdC1tb2RlbDgBQgluYXJyYXRpb25aJDAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwMDAwMRIM2CHSxu8c1K5jpBhyGgzQK5PxC+Mju2XXhKwiMA3oQ1tJM0jAx8vgGPWf5y7vvb1yMU0+TvfZGfAvF2WEKFdQJw5o1nCMHDzh4ofL9Co51j2qr3gk1B187fpKhQVksXH7vnKQeJuoa+uFFlMt5mfHSJyf1aD0IGRuoKnFS8bKKnBUzbY4ilmJGAE="

    /// The model's own reasoning, summarised.
    private let reasoning = "EswCCmUIDhgCKkBxSmgWfGxhcWkHTprVO4ad+wW0drclzpgqTxNK6+n+mOLcNs1+KodzVl8tSoz5aPC8MDyN5C0Mg6cSCvjOmJfAMhFjbGF1ZGUtdGVzdC1tb2RlbDgAQgh0aGlua2luZxIM/Rdwmp47Jkd6ZyktGgx/lu4kt9BZYZB6iTMiMHAt2TOS4wyoixbJ1cPoyUaSs0KO5QgQZSfa4uTdCN4XnvY5Stuy5VVk5wzew1IIgCqUARzmBv/d2Z506gA+zoMPjuM7KmRW600CV7Y0MsIyHkD1t/DbtxqNsbvQ3VmB8Z1onMoaWY/s1nuQzWYHW2umwYBXTKeMeQEG9dFQiNfZMKVquk1G3+krye+Nm+9k1OQf564NfdC7V6OG/LTD7PsnXjMRaDnfeWhrIg2XJ2sLftDFQOd6h8kGYJTKpfnxd2p4eF8Ts4cYAQ=="

    /// An older envelope that parses far enough to walk and then
    /// carries no kind — the case the fail-closed rule is actually for.
    private let legacy = "Eo0CClsIDBgCKkAP38VMhDWquAwF9ZMjR3FHLV2SfT+LwBN8dcN6SiIOdLoBy7XyoaDeWYWd9qlV24AFUbHviSnCa1TRHtYluefeMhFjbGF1ZGUtdGVzdC1tb2RlbDgAEgx8rosZdmumV3NVvOsaDDpKX1qwNLpn63aSACIwjQxf/7+vrIvp9ySvscztM3ijfG6VZVWc4K7SxJsqVAEHJEGAbkrgRdne25JryXdlKmC7K0uMq36b8vx9vYZ7B+LKnk5M0SpLYK1mMC+8+GPrtqM/6wKvrPfKpsHIpGbhzfyuWDiql3/S7PVxprrUg0B6G3ei/rVCI2bU6JayEpAo4hz1NcjjTrWzPFIq3ivWdbMYAQ=="

    func testReadsNarrationOffTheEnvelope() {
        XCTAssertEqual(NarrationSignature.blockKind(of: narrationWithText), "narration")
        XCTAssertEqual(NarrationSignature.blockKind(of: narrationWithoutText), "narration")
        XCTAssertTrue(NarrationSignature.isNarration(narrationWithText))
    }

    /// The distinction the whole change rests on: reasoning stays a Thought.
    func testReasoningIsNotNarration() {
        XCTAssertEqual(NarrationSignature.blockKind(of: reasoning), "thinking")
        XCTAssertFalse(NarrationSignature.isNarration(reasoning))
    }

    /// Every way of failing lands on "ordinary thinking", never on narration —
    /// the safe direction, since drawing reasoning as speech would put words in
    /// the model's mouth.
    func testFailsClosed() {
        XCTAssertNil(NarrationSignature.blockKind(of: legacy))
        XCTAssertFalse(NarrationSignature.isNarration(legacy))
        XCTAssertFalse(NarrationSignature.isNarration(nil))
        XCTAssertFalse(NarrationSignature.isNarration(""))
        XCTAssertFalse(NarrationSignature.isNarration("not base64 at all !!!"))
        XCTAssertFalse(NarrationSignature.isNarration("YWJjZGVm"))
        XCTAssertFalse(NarrationSignature.isNarration(String(narrationWithText.dropLast(40))))
    }

    /// Real headers carry more after the kind: a 16-byte field 14, then fields
    /// 17, 21 and 22 as varints, whose tags take two bytes. The walker has to
    /// step over all of them and still hand back field 8.
    func testReadsTheKindPastTrailingHeaderFields() {
        func varint(_ value: UInt64) -> [UInt8] {
            var value = value, out: [UInt8] = []
            while value >= 0x80 { out.append(UInt8(value & 0x7F) | 0x80); value >>= 7 }
            return out + [UInt8(value)]
        }
        func tag(_ number: UInt64, _ wire: UInt64) -> [UInt8] { varint(number << 3 | wire) }
        func bytes(_ number: UInt64, _ payload: [UInt8]) -> [UInt8] {
            tag(number, 2) + varint(UInt64(payload.count)) + payload
        }
        let header = tag(1, 0) + varint(17)
            + bytes(8, Array("narration".utf8))
            + tag(11, 0) + varint(300)
            + bytes(14, Array(repeating: 0xAB, count: 16))
            + tag(17, 0) + varint(1)
            + tag(21, 0) + varint(70_000)
            + tag(22, 0) + varint(2)
        let envelope = bytes(1, header) + bytes(2, Array(repeating: 0x5A, count: 48))
        let signature = Data(tag(1, 0) + varint(2) + bytes(2, envelope)).base64EncodedString()

        XCTAssertEqual(Array(tag(17, 0)), [0x88, 0x01])
        XCTAssertEqual(NarrationSignature.blockKind(of: signature), "narration")
        XCTAssertNil(NarrationSignature.blockKind(of: String(signature.dropLast(8))))
    }

    /// A signature that arrives short of its padding still reads, because
    /// failing closed on a real narration block is a silent revert to the bug
    /// rather than a safe stop.
    func testUnpaddedSignatureStillReads() {
        let unpadded = narrationWithText.replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(NarrationSignature.blockKind(of: unpadded), "narration")
    }
}
