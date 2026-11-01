import Foundation

extension LinearIssueMention {
    /// What a pasted link to this issue shows.
    public var resolution: LinkResolution {
        let state: LinkState? = switch stateType {
        case "completed": .done
        case "canceled": .closed
        default: nil
        }
        return LinkResolution(title: title, detail: detail, state: state)
    }
}

extension NotionPageMention {
    public var resolution: LinkResolution {
        LinkResolution(title: title, detail: detail.isEmpty ? nil : detail)
    }
}
