import Foundation
import IOKit.hid

/// Describes one HID interface of the AULA receiver/mouse.
public struct HIDInterface: Equatable {
    public let vendorID: Int
    public let productID: Int
    public let usagePage: Int
    public let usage: Int
    public let maxInputReportSize: Int
    public let maxOutputReportSize: Int
    public let maxFeatureReportSize: Int
    public let product: String
    public let transport: String
    public let locationID: Int
    public let reportDescriptor: [UInt8]
}

public enum AulaIDs {
    /// VID/PID taken from hid_enumerate(0x1d57, 0xfa60) in the Windows Mouse.exe
    /// (confirmed with the "LXDDZ" dongle on this machine: idVendor 7511, ProductID 64096).
    public static let vendorID = 0x1D57
    public static let productID = 0xFA60
}

/// The three connection paths the original app uses (Mouse.exe): different VID/PID, same command packets. Receiver and Bluetooth are verified; wired is not.
public enum AulaConnection: CaseIterable, Sendable {
    case dongle, wired, bluetooth
    public var vendorID: Int { self == .bluetooth ? 0x045E : 0x1D57 }
    public var productID: Int {
        switch self { case .dongle: 0xFA60; case .wired: 0x205E; case .bluetooth: 0x008E }
    }
    public var title: String {
        switch self { case .dongle: "2.4G Dongle"; case .wired: "Wired"; case .bluetooth: "Bluetooth" }
    }
}

public enum HIDDevices {
    private static func int(_ d: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? 0
    }
    private static func str(_ d: IOHIDDevice, _ key: String) -> String {
        (IOHIDDeviceGetProperty(d, key as CFString) as? String) ?? ""
    }

    /// Lists the HID interfaces matching the VID/PID. Reads metadata only: does not open the device or send anything.
    public static func list(vendorID: Int = AulaIDs.vendorID,
                            productID: Int = AulaIDs.productID) -> [HIDInterface] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return set.map { d in
            HIDInterface(
                vendorID: int(d, kIOHIDVendorIDKey),
                productID: int(d, kIOHIDProductIDKey),
                usagePage: int(d, kIOHIDPrimaryUsagePageKey),
                usage: int(d, kIOHIDPrimaryUsageKey),
                maxInputReportSize: int(d, kIOHIDMaxInputReportSizeKey),
                maxOutputReportSize: int(d, kIOHIDMaxOutputReportSizeKey),
                maxFeatureReportSize: int(d, kIOHIDMaxFeatureReportSizeKey),
                product: str(d, kIOHIDProductKey),
                transport: str(d, kIOHIDTransportKey),
                locationID: int(d, kIOHIDLocationIDKey),
                reportDescriptor: ((IOHIDDeviceGetProperty(d, kIOHIDReportDescriptorKey as CFString) as? Data).map { [UInt8]($0) }) ?? [])
        }.sorted { ($0.usagePage, $0.usage) < ($1.usagePage, $1.usage) }
    }
}
