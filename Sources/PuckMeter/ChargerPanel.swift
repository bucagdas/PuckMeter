import AppKit
import SwiftUI

/// Content of the menu bar panel, laid out like the system Battery module.
struct ChargerPanel: View {
    let monitor: ChargerMonitor
    let notifier: Notifier
    let launchAtLogin: LaunchAtLogin

    @State private var showsDetails: Bool

    init(monitor: ChargerMonitor, notifier: Notifier, launchAtLogin: LaunchAtLogin, showsDetails: Bool = false) {
        self.monitor = monitor
        self.notifier = notifier
        self.launchAtLogin = launchAtLogin
        _showsDetails = State(initialValue: showsDetails)
    }

    private var charger: Charger? { monitor.chargers.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !monitor.events.isEmpty {
                PanelDivider()
                SectionTitle("Recent Events")
                ForEach(Array(monitor.events.prefix(4))) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: event.date.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(verbatim: event.message)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                }
            }

            PanelDivider()
            SectionTitle("Measurement Source")
            ForEach(MeasurementSource.allCases) { source in
                Button {
                    monitor.source = source
                } label: {
                    IconRow(symbol: source == .smc ? "waveform" : "clock",
                            tint: .accentColor,
                            isProminent: monitor.source == source,
                            title: source.title)
                }
                .buttonStyle(HoverRowStyle())
            }

            if let charger {
                PanelDivider()
                Button {
                    showsDetails.toggle()
                } label: {
                    HStack {
                        Text("Charger Details")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showsDetails ? 90 : 0))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(HoverRowStyle())

                if showsDetails {
                    details(for: charger)
                }
            }

            PanelDivider()
            ToggleRow(title: "Notifications", isOn: Binding(get: { notifier.isEnabled }, set: { notifier.set($0) }))
                .help("When charging finishes and when iPhone charges from the Mac's battery")
            if notifier.isEnabled, !notifier.isAllowedBySystem {
                HStack {
                    Text("Turned off in System Settings")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings") { notifier.openSystemSettings() }
                        .buttonStyle(.link)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
            }
            ToggleRow(title: "Launch at Login", isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.set($0) }))

            PanelDivider()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Text("Quit PuckMeter")
                    Spacer()
                    Text(verbatim: "⌘Q").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(HoverRowStyle())
            .keyboardShortcut("q")
        }
        .font(.system(size: 13))
        .padding(6)
        .frame(width: 300)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("MagSafe Charger")
                Spacer()
                if let charger, let power = monitor.power(for: charger) {
                    Text(verbatim: power.wattsText).monospacedDigit()
                }
            }
            .font(.system(size: 13, weight: .bold))
            .padding(.bottom, 4)

            Group {
                if let charger {
                    Text(verbatim: monitor.statusTitle(for: charger))
                    if let power = monitor.power(for: charger) {
                        Text(verbatim: "\(power.milliamps) mA · \(power.voltsText)"
                            + (power.isLive ? "" : " · " + String(localized: "Updated every minute")))
                            .monospacedDigit()
                    } else if charger.usbCPort == nil {
                        Text("Connected through a hub or display")
                    }
                    if monitor.macOnBattery, monitor.state(for: charger) == .charging {
                        Text("Using the Mac's battery")
                    }
                } else {
                    Text("Not Connected")
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func details(for charger: Charger) -> some View {
        VStack(spacing: 3) {
            InfoRow(label: "Port", value: charger.usbCPort.map { "USB-C \($0)" } ?? String(localized: "Hub or display"))
            InfoRow(label: "Serial Number", value: charger.serialNumber) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(charger.serialNumber, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Copy Serial Number")
                .accessibilityLabel("Copy Serial Number")
            }
            if let release = charger.deviceReleaseText {
                InfoRow(label: "Version", value: release)
            }
            if let allocated = charger.powerText {
                InfoRow(label: "Allocated Power", value: allocated)
            }
            if let speed = charger.linkSpeedText {
                InfoRow(label: "USB Speed", value: speed)
            }
            InfoRow(label: "Connected", value: charger.connectedAt?.formatted(date: .omitted, time: .shortened)
                ?? String(localized: "Before the app started"))
        }
        .padding(.vertical, 2)
    }
}

private struct SectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }
}

private struct PanelDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }
}

/// A row with a round icon, like the Energy Mode choices.
private struct IconRow: View {
    let symbol: String
    let tint: Color
    let isProminent: Bool
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isProminent ? Color.white : Color.primary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(isProminent ? tint : Color.primary.opacity(0.12)))
            Text(verbatim: title)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

private struct ToggleRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

private struct InfoRow<Accessory: View>: View {
    let label: LocalizedStringKey
    let value: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: value).textSelection(.enabled)
            accessory
        }
        .padding(.horizontal, 8)
    }
}

extension InfoRow where Accessory == EmptyView {
    init(label: LocalizedStringKey, value: String) {
        self.init(label: label, value: value) { EmptyView() }
    }
}

/// Rounded hover highlight used by system menus.
private struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(isPressed: configuration.isPressed) {
            configuration.label
        }
    }

    private struct HoverRow<Content: View>: View {
        let isPressed: Bool
        @ViewBuilder var content: Content
        @State private var isHovering = false

        var body: some View {
            content
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(isPressed ? 0.16 : isHovering ? 0.08 : 0))
                )
                .onHover { isHovering = $0 }
        }
    }
}
