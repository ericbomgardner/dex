import DexCore
import Foundation

extension SessionStore {
    func installLinkedLookups() {
        let lookup = LinkedWorkLookup(work: linkedWork)
        Task {
            await ComposerLinkPaste.resolver.install(lookup, for: .linear)
            await ComposerLinkPaste.resolver.install(lookup, for: .notion)
        }
    }

    func linkedCandidates(for query: String) async -> LinkedCandidates {
        await linkedWork.candidates(for: query)
    }
}
