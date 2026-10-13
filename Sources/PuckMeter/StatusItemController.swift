import AppKit
import Observation
import SwiftUI

/// Menu bar item with a borderless glass panel. MenuBarExtra always draws a
/// square background, so the window is managed here instead.
@MainActor
final class StatusItemController {
    private static let cornerRadius: CGFloat = 16
    private static let gapBelowMenuBar: CGFloat = 6

    private let monitor: ChargerMonitor
    private let notifier: Notifier
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = GlassPanel()
    private var hostingView: NSView?
    private var pendingContentSize: CGSize?
    private var isResizing = false
    private var eventMonitors: [Any] = []

    init(monitor: ChargerMonitor, notifier: Notifier, launchAtLogin: LaunchAtLogin) {
        self.monitor = monitor
        self.notifier = notifier

        // SwiftUI reports the content's ideal size; the window follows it.
        let content = ChargerPanel(monitor: monitor, notifier: notifier, launchAtLogin: launchAtLogin)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
                self?.scheduleResize(to: size)
            }
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        hostingView.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        self.hostingView = hostingView

        // The glass sits behind the content instead of wrapping it, so it always
        // fills the window rather than sizing itself to the content.
        let container = FlippedView(frame: hostingView.frame)
        let background = Self.makeBackground()
        background.frame = container.bounds
        background.autoresizingMask = [.width, .height]
        container.addSubview(background)
        container.addSubview(hostingView)
        panel.contentView = container
        hostingView.layoutSubtreeIfNeeded()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.imagePosition = .imageLeading
        }
        updateButton()
    }

    private func updateButton() {
        withObservationTracking {
            guard let button = statusItem.button else { return }
            let charger = monitor.chargers.first
            let state = charger.flatMap(monitor.state(for:))
            let image = NSImage(systemSymbolName: Self.symbol(charger: charger, state: state), accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
            if state == .charging, let charger, let power = monitor.power(for: charger) {
                button.title = power.wattsText
            } else {
                button.title = ""
            }
            button.setAccessibilityLabel(charger.map(monitor.statusTitle(for:)) ?? String(localized: "Charger not connected"))
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateButton() }
        }
    }

    private static func symbol(charger: Charger?, state: ChargingState?) -> String {
        guard charger != nil else { return "bolt.slash.circle" }
        switch state {
        case .charging: return "bolt.circle.fill"
        case .noPhone, nil: return "bolt.circle"
        }
    }

    @objc private func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        notifier.refreshSystemPermission()
        // SwiftUI defers layout while the window is hidden; flush it so the size is current.
        hostingView?.needsLayout = true
        hostingView?.layoutSubtreeIfNeeded()
        if let size = pendingContentSize {
            pendingContentSize = nil
            resizePanel(to: size)
        }
        positionPanel()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            // The shadow must follow the rounded glass, which only exists once drawn.
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        }
        statusItem.button?.highlight(true)

        let outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
        let escapeKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.hidePanel() }
            return nil
        }
        eventMonitors = [outsideClick, escapeKey].compactMap { $0 }
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors = []
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
    }

    private func positionPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visibleFrame = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = panel.frame.size
        let x = min(max(buttonFrame.minX, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        let y = buttonFrame.minY - Self.gapBelowMenuBar - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Resizing inside SwiftUI's geometry callback re-enters it and AppKit then
    /// applies the size change twice, so resizes run on the next turn, coalesced.
    private func scheduleResize(to size: CGSize) {
        let alreadyScheduled = pendingContentSize != nil
        pendingContentSize = size
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let size = self.pendingContentSize else { return }
                self.pendingContentSize = nil
                self.resizePanel(to: size)
            }
        }
    }

    /// Resizes the window to the content, keeping its top edge under the menu bar.
    private func resizePanel(to contentSize: CGSize) {
        guard !isResizing, let hostingView, contentSize.width > 0, contentSize.height > 0 else { return }
        isResizing = true
        defer { isResizing = false }
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 800) - 2 * Self.gapBelowMenuBar
        let size = CGSize(width: contentSize.width, height: min(contentSize.height, maxHeight))
        guard size != panel.frame.size || size != hostingView.frame.size || size != panel.contentView?.frame.size else { return }

        var frame = panel.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        panel.setFrame(frame, display: true)
        let bounds = CGRect(origin: .zero, size: size)
        panel.contentView?.frame = bounds
        hostingView.frame = bounds
        panel.invalidateShadow()
    }

    private static func makeBackground() -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            // Clipping the layer makes the window shadow follow the rounded shape.
            glass.wantsLayer = true
            glass.layer?.cornerRadius = cornerRadius
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: 10)
        return effect
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let length = radius * 2 + 1
        let image = NSImage(size: NSSize(width: length, height: length), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Top-left origin, so the content stays pinned to the top while sizes settle.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class GlassPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
}
