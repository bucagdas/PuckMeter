import AppKit
import UserNotifications

@main
enum PuckMeterApp {
    @MainActor
    static func main() {
        // `PuckMeter --status` prints the current state and exits.
        if CommandLine.arguments.contains("--status") {
            printStatus(of: ChargerMonitor())
            return
        }
        if CommandLine.arguments.contains("--test-notification") {
            let sent = DispatchSemaphore(value: 0)
            Notifier.deliver(String(localized: "Notifications are working")) { sent.signal() }
            _ = sent.wait(timeout: .now() + 5)
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    @MainActor
    private static func printStatus(of monitor: ChargerMonitor) {
        print("Mac: \(monitor.macOnBattery ? "on battery" : "on power adapter")")
        print("Notifications: \(notificationStatus())")
        guard !monitor.chargers.isEmpty else {
            print("MagSafe Charger: not connected")
            return
        }
        for charger in monitor.chargers {
            let power = monitor.power(for: charger)
            print("MagSafe Charger: connected")
            print("  Port:    \(charger.usbCPort.map { "USB-C \($0)" } ?? "through a hub or display")")
            print("  State:   \(monitor.statusTitle(for: charger))")
            print("  Power:   \(power?.detailText ?? "-")")
            print("  Source:  \(power.map { $0.isLive ? "SMC (live)" : "PowerOutDetails (every minute)" } ?? "-")")
            print("  Serial:  \(charger.serialNumber)")
            print("  Version: \(charger.deviceReleaseText ?? "-")")
            print("  Budget:  \(charger.powerText ?? "-")")
            print("  Speed:   \(charger.linkSpeedText ?? "-")")
        }
    }

    private static func notificationStatus() -> String {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status = "unknown"
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: status = "allowed"
            case .denied: status = "denied"
            case .notDetermined: status = "not requested yet"
            @unknown default: status = "unknown"
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
        return status
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let notifier = Notifier()
        statusItemController = StatusItemController(
            monitor: ChargerMonitor(onNotify: { notifier.post($0) }),
            notifier: notifier,
            launchAtLogin: LaunchAtLogin()
        )
    }
}
