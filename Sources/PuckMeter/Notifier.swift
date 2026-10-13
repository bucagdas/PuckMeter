import AppKit
import Observation
import UserNotifications

@MainActor
@Observable
final class Notifier {
    private static let enabledKey = "notificationsEnabled"

    private(set) var isEnabled: Bool
    /// false when macOS blocks notifications for the app (System Settings > Notifications).
    private(set) var isAllowedBySystem = true

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        if isEnabled {
            requestAuthorization()
        }
    }

    func set(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            requestAuthorization()
        }
    }

    func post(_ event: ChargeEvent) {
        guard isEnabled else { return }
        Self.deliver(event.message)
    }

    nonisolated static func deliver(_ message: String, completion: (@Sendable () -> Void)? = nil) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "MagSafe Charger")
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("PuckMeter: notification failed: \(error.localizedDescription)")
            }
            completion?()
        }
    }

    func refreshSystemPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let allowed = settings.authorizationStatus != .denied
            Task { @MainActor in self?.isAllowedBySystem = allowed }
        }
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if let error {
                NSLog("PuckMeter: notification authorization failed: \(error.localizedDescription)")
            }
            Task { @MainActor in self?.refreshSystemPermission() }
        }
    }
}
