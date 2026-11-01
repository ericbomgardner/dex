import Foundation

public protocol OpenEnum: Codable, Hashable, Sendable, CustomStringConvertible {
    init(raw: String)
    var raw: String { get }
}

extension OpenEnum {
    public init(from decoder: any Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    public var description: String { raw }
}
