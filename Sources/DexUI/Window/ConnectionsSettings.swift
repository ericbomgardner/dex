import DexCore
import SwiftUI

/// The tokens `@` reads Linear issues and Notion pages with, and how the last
/// use of each went.
struct ConnectionsSection: View {
    let work: LinkedWork

    var body: some View {
        Section("Connections") {
            ForEach(LinkedService.allCases) { service in
                LinkedTokenRow(work: work, service: service)
            }
            SlackTokenRow()
            GitHubCLINote()

            Text("Linear issues and Notion pages are offered after @, and a link to any of these pasted into the composer becomes a chip with its title. \(ConnectionTokens.whereKept)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .task {
            await work.load()
            for service in LinkedService.allCases where work.status(of: service) == .unchecked {
                await work.check(service)
            }
        }
    }
}

struct LinkedTokenRow: View {
    let work: LinkedWork
    let service: LinkedService

    @State private var draft = ""

    private var status: LinkedServiceStatus { work.status(of: service) }

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
            HStack(spacing: ChromeMetrics.inlineGap) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(service.name)
                Spacer(minLength: ChromeMetrics.inlineGap)
                Text(label)
                    .foregroundStyle(.secondary)
                if case .unreadable = status {
                    Button("Retry") { Task { await work.retry(service) } }
                        .buttonStyle(.borderless)
                } else if work.hasToken(service) {
                    Button("Check") { Task { await work.check(service) } }
                        .buttonStyle(.borderless)
                }
                if work.hasToken(service) || status.isUnreadable {
                    Button("Remove") { work.setToken("", for: service) }
                        .buttonStyle(.borderless)
                }
            }

            if case .failed(let message, let at) = status {
                Text("\(message) (\(at.formatted(date: .omitted, time: .standard)))")
                    .font(ChromeType.meta)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: ChromeMetrics.inlineGap) {
                SecureField(work.hasToken(service) || status.isUnreadable ? "Replace token" : "Token", text: $draft, prompt: Text(prompt))
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text(help)
                .font(ChromeType.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, ChromeMetrics.lineGap)
    }

    private func save() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        work.setToken(draft, for: service)
        draft = ""
    }

    private var label: String {
        switch status {
        case .reading: "Reading…"
        case .unreadable: "Couldn't read from the keychain"
        case .noToken: "No token"
        case .unchecked: "Checking…"
        case .connected(let who, _): who.map { "Connected as \($0)" } ?? "Connected"
        case .failed: "Not working"
        }
    }

    private var color: Color {
        switch status {
        case .connected: .green
        case .failed: .red
        case .unreadable: .orange
        case .reading, .noToken, .unchecked: .secondary
        }
    }

    private var prompt: String {
        switch service {
        case .linear: "lin_api_…"
        case .notion: "ntn_…"
        }
    }

    private var help: String {
        switch service {
        case .linear:
            "A personal API key, from Linear → Settings → Account → Security & access."
        case .notion:
            "An internal integration's secret, from notion.so/profile/integrations. It sees only the pages shared with it: a page's ••• menu → Connections."
        }
    }
}
