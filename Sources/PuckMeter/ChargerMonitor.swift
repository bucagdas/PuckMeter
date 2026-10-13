import Foundation
import IOKit
import Observation

/// An Apple MagSafe Charger (USB 05ac:0500) from the IORegistry.
struct Charger: Identifiable, Equatable {
    let id: UInt64
    let serialNumber: String
    let deviceRelease: Int?
    let powerAllocatedMilliamps: Int?
    let linkSpeedBitsPerSecond: Int?
    /// nil behind a hub or display, where the Mac is not the power source.
    let usbCPort: Int?
    /// nil when the charger was already connected at launch.
    let connectedAt: Date?

    var deviceReleaseText: String? {
        deviceRelease.map { String(format: "0x%04X", $0) }
    }

    /// USB allocates power at 5 V.
    var powerText: String? {
        powerAllocatedMilliamps.map { "\($0 * 5 / 1000) W (\($0) mA)" }
    }

    var linkSpeedText: String? {
        linkSpeedBitsPerSecond.map { "\($0 / 1_000_000) Mb/s" }
    }
}

struct ChargeEvent: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
    let notifies: Bool
}

enum MeasurementSource: String, CaseIterable, Identifiable {
    case smc
    case batteryReport

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smc: String(localized: "SMC (Live)")
        case .batteryReport: String(localized: "Battery Report (Every Minute)")
        }
    }
}

/// Watches the charger's USB node and the power the Mac sources on its port.
/// Read only: it never opens the charger, so macOS' UARP session is untouched.
@MainActor
@Observable
final class ChargerMonitor {
    static let vendorID = 0x05AC
    static let productID = 0x0500
    private static let maxEvents = 8
    private static let sourceKey = "measurementSource"

    private(set) var chargers: [Charger] = []
    private(set) var readings: [UInt64: PortPower] = [:]
    private(set) var states: [UInt64: ChargingState] = [:]
    private(set) var events: [ChargeEvent] = []
    private(set) var macOnBattery = false

    var source: MeasurementSource {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
            detectors = [:]
        }
    }

    @ObservationIgnored private let onNotify: ((ChargeEvent) -> Void)?
    @ObservationIgnored private var detectors: [UInt64: ChargeDetector] = [:]
    @ObservationIgnored private var warnedAboutBatteryDrain = false
    @ObservationIgnored private let notifyPort: IONotificationPortRef
    @ObservationIgnored private var attachIterator: io_iterator_t = 0
    @ObservationIgnored private var detachIterator: io_iterator_t = 0
    @ObservationIgnored private var pollTimer: Timer?

    init(onNotify: ((ChargeEvent) -> Void)? = nil) {
        self.onNotify = onNotify
        source = UserDefaults.standard.string(forKey: Self.sourceKey).flatMap(MeasurementSource.init) ?? .smc
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        IOServiceAddMatchingNotification(notifyPort, kIOFirstMatchNotification, Self.matchingDictionary(), { refcon, iterator in
            let monitor = Unmanaged<ChargerMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.handleAttached(iterator, isInitialScan: false) }
        }, refcon, &attachIterator)

        IOServiceAddMatchingNotification(notifyPort, kIOTerminatedNotification, Self.matchingDictionary(), { refcon, iterator in
            let monitor = Unmanaged<ChargerMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.handleDetached(iterator) }
        }, refcon, &detachIterator)

        // Draining the iterators arms the notifications and finds chargers already connected.
        handleAttached(attachIterator, isInitialScan: true)
        handleDetached(detachIterator)
        refreshPower()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPower() }
        }
    }

    func power(for charger: Charger) -> PortPower? {
        readings[charger.id]
    }

    func state(for charger: Charger) -> ChargingState? {
        states[charger.id]
    }

    func statusTitle(for charger: Charger) -> String {
        guard charger.usbCPort != nil else { return String(localized: "Power Not Measurable") }
        return state(for: charger)?.title ?? String(localized: "No Reading")
    }

    private func refreshPower() {
        for charger in chargers {
            guard let reading = reading(for: charger) else { continue }
            var detector = detectors[charger.id] ?? ChargeDetector()
            let state = detector.add(reading)
            detectors[charger.id] = detector

            readings[charger.id] = PortPower(
                milliwatts: Int((detector.smoothedWatts(at: reading.measuredAt) * 1000).rounded()),
                milliamps: reading.milliamps,
                millivolts: reading.millivolts,
                measuredAt: reading.measuredAt,
                isLive: reading.isLive
            )

            if let previous = states[charger.id], previous != state,
               let transition = Self.transition(from: previous, to: state) {
                record(transition.message, at: reading.measuredAt, notifies: transition.notifies)
            }
            if states[charger.id] != state {
                states[charger.id] = state
            }
        }

        let onBattery = MacPowerSource.isOnBattery() ?? false
        if onBattery != macOnBattery {
            macOnBattery = onBattery
        }
        let drainingMacBattery = onBattery && states.values.contains(.charging)
        if drainingMacBattery, !warnedAboutBatteryDrain {
            record(String(localized: "Charging from the Mac's battery"), notifies: true)
        }
        warnedAboutBatteryDrain = drainingMacBattery
    }

    private func reading(for charger: Charger) -> PortPower? {
        guard let port = charger.usbCPort else { return nil }
        switch source {
        case .smc:
            return SMCPortSensor.read(port: port) ?? BatteryPortPowerReader.read(port: port)
        case .batteryReport:
            return BatteryPortPowerReader.read(port: port)
        }
    }

    private static func transition(from old: ChargingState, to new: ChargingState) -> (message: String, notifies: Bool)? {
        switch (old, new) {
        case (.noPhone, .charging): (String(localized: "Charging started"), false)
        case (_, .noPhone): (String(localized: "iPhone removed"), false)
        default: nil
        }
    }

    private func record(_ message: String, at date: Date = Date(), notifies: Bool = false) {
        let event = ChargeEvent(date: date, message: message, notifies: notifies)
        events.insert(event, at: 0)
        if events.count > Self.maxEvents {
            events.removeLast(events.count - Self.maxEvents)
        }
        if notifies {
            onNotify?(event)
        }
    }

    private static func matchingDictionary() -> CFMutableDictionary {
        let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching["idVendor"] = vendorID
        matching["idProduct"] = productID
        return matching
    }

    private func handleAttached(_ iterator: io_iterator_t, isInitialScan: Bool) {
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let charger = Self.readCharger(service, connectedAt: isInitialScan ? nil : Date()),
                  !chargers.contains(where: { $0.id == charger.id })
            else { continue }
            chargers.append(charger)
            if !isInitialScan {
                record(String(localized: "Charger connected"))
            }
        }
    }

    private func handleDetached(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
                  chargers.contains(where: { $0.id == entryID })
            else { continue }
            chargers.removeAll { $0.id == entryID }
            readings[entryID] = nil
            states[entryID] = nil
            detectors[entryID] = nil
            record(String(localized: "Charger disconnected"))
        }
    }

    private static func readCharger(_ service: io_service_t, connectedAt: Date?) -> Charger? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }

        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanagedProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any]
        else { return nil }

        return Charger(
            id: entryID,
            serialNumber: properties["USB Serial Number"] as? String ?? properties["kUSBSerialNumberString"] as? String ?? "-",
            deviceRelease: properties["bcdDevice"] as? Int,
            powerAllocatedMilliamps: properties["UsbPowerSinkAllocation"] as? Int,
            linkSpeedBitsPerSecond: properties["UsbLinkSpeed"] as? Int,
            usbCPort: directUSBCPort(of: service),
            connectedAt: connectedAt
        )
    }

    /// A charger plugged straight into the Mac sits under a native root port
    /// ("usb-drd*") whose PortNumber matches the SMC and PowerOutDetails port.
    private static func directUSBCPort(of service: io_service_t) -> Int? {
        var parent: io_registry_entry_t = IO_OBJECT_NULL
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }

        var nameBuffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(parent, &nameBuffer) == KERN_SUCCESS else { return nil }
        let name = nameBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }

        func property(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(parent, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        }
        // PortType 2 is USB-C.
        guard name.hasPrefix("usb-drd"), property("PortType") == 2 else { return nil }
        return property("PortNumber")
    }
}
