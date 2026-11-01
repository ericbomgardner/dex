import DexCore
import AppKit
import SwiftUI

/// Drives a real menu checkmark from state the menu doesn't own. Tapping runs the
/// action either way, so re-picking what's already checked doesn't uncheck it.
@MainActor
func menuCheck(_ isOn: Bool, tap: @escaping @MainActor () -> Void) -> Binding<Bool> {
    Binding(get: { isOn }, set: { _ in MainActor.assumeIsolated(tap) })
}

/// Filters the list. "All Projects" is a choice here, unlike in the composer.
struct ProjectPicker: View {
    @Bindable var store: SessionStore

    var labelFont: Font = ChromeType.body.weight(.medium)

    var body: some View {
        Menu {
            Toggle(isOn: menuCheck(store.selectedProject == nil) { store.selectedProject = nil }) {
                Text("All Projects")
            }

            ProjectMenuItems(projects: store.projects, chosen: store.selectedProject) {
                store.selectedProject = $0
            }
        } label: {
            ProjectLabel(name: store.selectedProjectName ?? "All Projects", font: labelFont)
        }
        .menuStyle(.borderlessButton)
        .untinted()
        .fixedSize()
        .help(filterHelp)
    }

    private var filterHelp: String {
        let showing = store.selectedProject.map { Format.tildePath($0) } ?? "Showing every project"
        return "\(showing) — ⌘K to switch"
    }
}

/// Picks the folder a new session starts in. While the list is filtered to one
/// project every new session lands there, so this drops to a plain label.
struct ComposerProjectPicker: View {
    @Bindable var store: SessionStore

    private let labelFont = ChromeType.body.weight(.medium)

    var body: some View {
        if store.composerFollowsFilter {
            ProjectLabel(name: store.composerTargetName, font: labelFont)
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("Filtered to \(Format.tildePath(store.composerTarget)), so new sessions start there")
        } else {
            Menu {
                ProjectMenuItems(projects: store.composerFolders, chosen: store.composerTarget) {
                    store.composer.chooseProject($0)
                }
            } label: {
                ProjectLabel(name: store.composerTargetName, font: labelFont)
            }
            .menuStyle(.borderlessButton)
            .untinted()
            .fixedSize()
            .padding(.leading, -ChromeMetrics.menuInset)
            .help(Format.tildePath(store.composerTarget))
        }
    }
}

private struct ProjectLabel: View {
    let name: String
    let font: Font

    var body: some View {
        HStack(spacing: ChromeMetrics.iconGap) {
            Image(systemName: "folder")
                .font(ChromeType.inlineIcon)
            Text(name)
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: ChromeMetrics.projectNameSlot, alignment: .leading)
        }
    }
}

private struct ProjectMenuItems: View {
    let projects: [ProjectSummary]
    let chosen: String?
    let choose: (String) -> Void

    var body: some View {
        if !projects.isEmpty {
            Divider()
            ForEach(projects) { project in
                Toggle(isOn: menuCheck(chosen == project.path) { choose(project.path) }) {
                    Text(label(for: project))
                }
                .help(Format.tildePath(project.path))
            }
        }

        Divider()
        Button("Choose Folder…") { chooseFolder() }
    }

    private func label(for project: ProjectSummary) -> String {
        guard project.total > 0 else { return project.name }
        var text = "\(project.name)  (\(project.active))"
        if project.blocked > 0 { text += " · \(project.blocked) waiting" }
        return text
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Project"
        if let chosen {
            panel.directoryURL = URL(fileURLWithPath: chosen)
        }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            choose(url.path)
        }
    }
}
