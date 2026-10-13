import Foundation
import IOKit
import SMC

/// Power the Mac is sourcing on one USB-C port.
struct PortPower: Equatable {
    let milliwatts: Int
    let milliamps: Int
    let millivolts: Int
    let measuredAt: Date
    /// true for the SMC sensor (~1 Hz), false for the battery report (~1/min).
    let isLive: Bool

    var watts: Double { Double(milliwatts) / 1000 }

    var wattsText: String {
        watts.formatted(.number.precision(.fractionLength(1))) + " W"
    }

    var voltsText: String {
        (Double(millivolts) / 1000).formatted(.number.precision(.fractionLength(2))) + " V"
    }

    var detailText: String {
        "\(wattsText) · \(milliamps) mA · \(voltsText)"
    }
}

enum ChargingState: Equatable {
    case noPhone
    case charging

    var title: String {
        switch self {
        case .noPhone: String(localized: "No Phone")
        case .charging: String(localized: "Charging")
        }
    }
}

/// Reads SMC keys D<n>JI (A) and D<n>JV (V) for Port-USB-C@<n>. Read only.
enum SMCPortSensor {
    static func read(port: Int) -> PortPower? {
        guard smc_open() else { return nil }
        var amps: Float = 0
        var volts: Float = 0
        guard smc_read_float("D\(port)JI", &amps), smc_read_float("D\(port)JV", &volts) else { return nil }
        return PortPower(
            milliwatts: Int((amps * volts * 1000).rounded()),
            milliamps: Int((amps * 1000).rounded()),
            millivolts: Int((volts * 1000).rounded()),
            measuredAt: Date(),
            isLive: true
        )
    }
}

/// Fallback: AppleSmartBattery's PowerOutDetails, refreshed about once a minute.
enum BatteryPortPowerReader {
    static func read(port: Int) -> PortPower? {
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(battery) }

        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(battery, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        let ports = property("PowerOutDetails") as? [[String: Any]] ?? []
        // "Watts" is in milliwatts.
        guard let entry = ports.first(where: { $0["PortIndex"] as? Int == port }),
              let milliwatts = entry["Watts"] as? Int
        else { return nil }

        let updateTime = property("UpdateTime") as? Int
        return PortPower(
            milliwatts: milliwatts,
            milliamps: entry["Current"] as? Int ?? 0,
            millivolts: entry["AdapterVoltage"] as? Int ?? 0,
            measuredAt: updateTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date(),
            isLive: false
        )
    }
}

enum MacPowerSource {
    /// nil on Macs without a battery.
    static func isOnBattery() -> Bool? {
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(battery) }
        let external = IORegistryEntryCreateCFProperty(battery, "ExternalConnected" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
        return external.map { !$0 }
    }
}
