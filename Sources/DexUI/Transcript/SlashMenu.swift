import DexCore
import Observation
import SwiftUI

/// The commands on offer while the field holds a name and nothing else.
///
/// The catalogue is the CLI's own list plus whatever the user and the project
/// have written; it is read once per session attached, since a command added to
/// disk mid-session is not one the running CLI has picked up either.
@MainActor
@Observable
final class SlashMenu {

    private(set) var matches: [Command] = []
    private(set) var selection = 0

    private var catalogue: [Command] = []
    private var live: Set<String>?
    private var dismissed: String?

    init(catalogue: [Command] = []) {
        self.catalogue = catalogue
    }

    var isOpen: Bool { !matches.isEmpty }

    /// Nil where the session cannot run it: a greyed row is shown so the list
    /// stays the CLI's own, and cannot be taken.
    var selected: Command? {
        guard matches.indices.contains(selection) else { return nil }
        let command = matches[selection]
        return command.isAvailable ? command : nil
    }

    /// - Parameter readsDisk: whether the commands on this machine's disk are
    ///   this session's.
    func load(project: String?, readsDisk: Bool = true) async {
        guard readsDisk else {
            catalogue = BuiltInCommands.all
            return restamp()
        }
        catalogue = await Task.detached(priority: .utility) {
            SlashCommands.all(forProject: project)
        }.value
        restamp()
    }

    /// What the attached session's CLI says it will run. Arrives on `init`,
    /// which the CLI emits once a turn, so a session says this again every time
    /// it is spoken to and the menu heals if it was ever wrong.
    func sessionRuns(_ names: [String]?) {
        let names = names.map(Set.init)
        guard names != live else { return }
        live = names
        restamp()
    }

    /// Stamps the open menu as well as the catalogue behind it: the list is
    /// offered from the moment a session is attached, and its first `init` can
    /// land while it is on screen.
    private func restamp() {
        catalogue = SlashCommands.marked(catalogue, live: live)
        guard !matches.isEmpty else { return }
        matches = SlashCommands.marked(matches, live: live)
        if selected == nil { selection = firstTakeable ?? 0 }
    }

    func draftChanged(to draft: String) {
        // Escape closes the menu for the name it was open on; typing on makes it
        // a different name, and the menu is worth offering again.
        if dismissed != nil, dismissed != draft { dismissed = nil }
        guard dismissed == nil else { return matches = [] }

        let found = SlashCompletion.matches(for: draft, in: catalogue)
        guard found != matches else { return }

        matches = found
        selection = firstTakeable ?? 0
    }

    /// Steps over the rows the session won't run, so holding an arrow down
    /// walks the list you can actually pick from. A search that matched nothing
    /// takeable leaves the cursor where it was rather than parking it on a row
    /// that Enter would ignore.
    func move(_ step: Int) {
        guard !matches.isEmpty, firstTakeable != nil else { return }
        var next = selection
        for _ in matches.indices {
            next = (next + step + matches.count) % matches.count
            if matches[next].isAvailable { return selection = next }
        }
    }

    private var firstTakeable: Int? {
        matches.firstIndex(where: \.isAvailable)
    }

    func dismiss(for draft: String) {
        dismissed = draft
        matches = []
    }

    func close() {
        matches = []
        selection = 0
        dismissed = nil
    }
}

struct SlashMenuList: View {
    let menu: SlashMenu
    let accept: (Command) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menu.matches.enumerated()), id: \.element.id) { index, command in
                row(command, isSelected: index == menu.selection && command.isAvailable)
            }
        }
        .padding(.vertical, ChromeMetrics.badgeVertical)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.fieldCorner, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(radius: ChromeMetrics.menuShadow, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChromeMetrics.fieldCorner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: ChromeMetrics.hairline)
        )
    }

    private func row(_ command: Command, isSelected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ChromeMetrics.inlineGap) {
            Text(command.typed)
                .font(ChromeType.body.weight(.medium))
                .foregroundStyle(name(isSelected: isSelected, isAvailable: command.isAvailable))

            Text(command.summary)
                .font(ChromeType.meta)
                .foregroundStyle(detail(isSelected: isSelected, isAvailable: command.isAvailable))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // Says which of the two it is rather than leaving the dimming to be
            // read as a guess: what a greyed row wants is the CLI's own reason,
            // which is that the command opens a panel a hosted session has not
            // got.
            if let badge = command.isAvailable ? (command.isCustom ? "custom" : nil) : "terminal only" {
                Text(badge)
                    .font(ChromeType.badge)
                    .foregroundStyle(detail(isSelected: isSelected, isAvailable: command.isAvailable))
            }
        }
        .padding(.horizontal, ChromeMetrics.fieldHorizontal)
        .padding(.vertical, ChromeMetrics.badgeVertical + 1)
        .background(isSelected ? ChromeColor.accent : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if command.isAvailable { accept(command) } }
    }

    private func name(isSelected: Bool, isAvailable: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.white) }
        return isAvailable ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
    }

    private func detail(isSelected: Bool, isAvailable: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.white.opacity(0.8)) }
        return isAvailable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary)
    }
}
