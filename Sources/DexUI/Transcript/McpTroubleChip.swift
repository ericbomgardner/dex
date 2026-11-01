import DexCore
import AppKit
import SwiftUI

/// MCP servers the session can't use: failed or wanting a login at startup, or
/// gone by the newest call to them. Absent while every server is fine.
struct McpTroubleChip: View {
    let pane: SessionPane
    let trouble: [McpTrouble]

    @State private var isShown = false

    private var label: String {
        trouble.count == 1 ? trouble[0].server : "\(trouble.count) MCP"
    }

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            HStack(spacing: ChromeMetrics.badgeGap) {
                Image(systemName: "powerplug.fill")
                    .font(ChromeType.badgeIcon)
                Text(label)
                    .font(ChromeType.badge.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, ChromeMetrics.badgeHorizontal)
            .padding(.vertical, ChromeMetrics.badgeVertical)
            .background(Capsule().fill(Color.orange.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help(trouble.count == 1 ? "\(label) \(trouble[0].kind.reason.lowercased())" : "\(trouble.count) MCP servers can't be used")
        .popover(isPresented: $isShown, arrowEdge: .top) {
            McpTroublePanel(pane: pane, trouble: trouble)
        }
    }
}

private struct McpTroublePanel: View {
    let pane: SessionPane
    let trouble: [McpTrouble]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(trouble.enumerated()), id: \.element.id) { index, server in
                if index > 0 { Divider() }
                McpTroubleRow(pane: pane, trouble: server)
            }
        }
        .frame(width: 340)
    }
}

private struct McpTroubleRow: View {
    let pane: SessionPane
    let trouble: McpTrouble

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    @State private var isWorking = false
    @State private var note: String?
    @State private var refusal: String?

    private enum Action {
        case logIn, reconnect, settings
    }

    private var awaitsReconnect: Bool { pane.awaitsMcpReconnect(trouble.server) }

    private var action: Action {
        guard pane.canMendMcp else { return .settings }
        guard trouble.kind == .needsAuth, !awaitsReconnect else { return .reconnect }
        return .logIn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.lineGap + 2) {
            HStack(alignment: .firstTextBaseline, spacing: ChromeMetrics.iconGap) {
                Image(systemName: "powerplug.fill")
                    .font(ChromeType.badgeIcon)
                    .foregroundStyle(.orange)
                Text(trouble.server)
                    .font(ChromeType.title.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(trouble.kind.reason)
                    .font(ChromeType.meta)
                    .foregroundStyle(.secondary)
                Spacer(minLength: ChromeMetrics.iconGap)
                button
            }
            if let detail = trouble.detail, !detail.isEmpty {
                Text(detail)
                    .font(ChromeType.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(note)
                    .font(ChromeType.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let refusal {
                Text(refusal)
                    .font(ChromeType.meta)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, ChromeMetrics.horizontal)
        .padding(.vertical, ChromeMetrics.rowVertical + 2)
    }

    @ViewBuilder private var button: some View {
        Group {
            switch action {
            case .logIn:
                Button(isWorking ? "Logging In…" : "Log In") { Task { await logIn() } }
            case .reconnect:
                Button(isWorking ? "Reconnecting…" : "Reconnect") { Task { await reconnect() } }
            case .settings:
                Button("Open Settings") { openSettings() }
                    .help("Dex isn't running this session, so it can't reconnect the server")
            }
        }
        .controlSize(.small)
        .disabled(isWorking)
    }

    private func reconnect() async {
        isWorking = true
        refusal = nil
        note = nil
        refusal = await pane.reconnectMcp(trouble)
        isWorking = false
    }

    private func logIn() async {
        isWorking = true
        refusal = nil
        switch await pane.loginMcp(trouble.server) {
        case .success(let start):
            if let url = start.url { openURL(url) }
            if start.reconnects, start.url != nil {
                note = "Finish logging in in your browser. This clears once the server connects."
            }
        case .failure(let failure):
            refusal = failure.reason
        }
        isWorking = false
    }
}

extension McpTrouble.Kind {
    var reason: String {
        switch self {
        case .failed: "Failed to start"
        case .needsAuth: "Needs login"
        case .unreachable: "Stopped responding"
        }
    }
}
