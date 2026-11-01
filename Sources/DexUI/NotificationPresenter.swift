import DexCore
import AppKit
import Foundation
import UserNotifications
import os

private let logger = Logger(subsystem: BundleIdentity.code, category: "notifications")

@MainActor
final class NotificationPresenter: NSObject {

    static let isAvailable = Bundle.main.bundleIdentifier != nil

    enum Authorization: Equatable {
        case unavailable
        case notRequested
        case granted
        case denied

        var note: String? {
            switch self {
            case .unavailable:
                "Only in the bundled app — build with Scripts/make-app.sh"
            case .denied:
                "Blocked in System Settings › Notifications"
            case .notRequested, .granted:
                nil
            }
        }
    }

    private(set) var authorization: Authorization = isAvailable ? .notRequested : .unavailable

    var onOpenSession: ((String) -> Void)?

    var onOpenWatchers: (() -> Void)?

    private nonisolated static let sessionIDKey = "sessionID"

    func prepare() {
        guard Self.isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorization()
    }

    func requestAuthorization() {
        guard Self.isAvailable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                if let error {
                    logger.error("notification authorization failed: \(String(describing: error), privacy: .public)")
                }
                Task { @MainActor in
                    self?.authorization = granted ? .granted : .denied
                }
            }
    }

    private func refreshAuthorization() {
        guard Self.isAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in

            let status = settings.authorizationStatus
            Task { @MainActor in
                switch status {
                case .authorized, .provisional, .ephemeral:
                    self?.authorization = .granted
                case .denied:
                    self?.authorization = .denied
                case .notDetermined:
                    self?.authorization = .notRequested
                @unknown default:
                    self?.authorization = .notRequested
                }
            }
        }
    }

    func post(_ draft: NotificationDraft) {
        guard Self.isAvailable else { return }

        let content = UNMutableNotificationContent()
        content.title = draft.title
        content.body = draft.body
        content.sound = .default
        if let sessionID = draft.sessionID {
            content.userInfo = [Self.sessionIDKey: sessionID]
        }
        content.threadIdentifier = draft.key

        // Filed under the row so later news replaces earlier news, rather than stacking.
        let request = UNNotificationRequest(
            identifier: draft.key,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("couldn't post notification: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Takes back every delivered notification whose row is filed but not listed.
    func keepOnly(_ rows: Set<String>) {
        guard Self.isAvailable else { return }

        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let stale = delivered.filter { note in
                let row = note.request.content.threadIdentifier
                return !row.isEmpty && !rows.contains(row)
            }
            guard !stale.isEmpty else { return }
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: stale.map(\.request.identifier))
        }
    }
}

extension NotificationPresenter: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        if content.threadIdentifier.hasPrefix(BackgroundWatcherAlert.keyPrefix) {
            await MainActor.run { self.onOpenWatchers?() }
            return
        }
        let userInfo = content.userInfo
        guard let sessionID = userInfo[NotificationPresenter.sessionIDKey] as? String else { return }
        await MainActor.run {
            self.onOpenSession?(sessionID)
        }
    }
}
