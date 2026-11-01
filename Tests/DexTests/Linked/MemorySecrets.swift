import DexCore
import Foundation

final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LinkedService: String]
    private var refused: [LinkedService: OSStatus]

    init(_ values: [LinkedService: String] = [:], refused: [LinkedService: OSStatus] = [:]) {
        self.values = values
        self.refused = refused
    }

    func reading(for service: LinkedService) -> TokenReading {
        lock.withLock {
            if let status = refused[service] { return .unreadable(status) }
            return values[service].map(TokenReading.found) ?? .missing
        }
    }

    func setSecret(_ value: String?, for service: LinkedService) throws {
        lock.withLock {
            refused[service] = nil
            values[service] = value?.isEmpty == false ? value : nil
        }
    }

    /// As a keychain that has started or stopped refusing does.
    func refuse(_ service: LinkedService, _ status: OSStatus?) {
        lock.withLock { refused[service] = status }
    }
}
