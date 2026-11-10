import Foundation
import IOKit.hid

public enum HIDError: Error, CustomStringConvertible {
    case controlInterfaceNotFound
    case openFailed(IOReturn)
    case sendFailed(IOReturn)
    public var description: String {
        switch self {
        case .controlInterfaceNotFound: return "Control interface not found (usage 0x80, 64-byte feature report)"
        case .openFailed(let r): return String(format: "IOHIDDeviceOpen failed: 0x%08X", UInt32(bitPattern: r))
        case .sendFailed(let r): return String(format: "IOHIDDeviceSetReport failed: 0x%08X", UInt32(bitPattern: r))
        }
    }
}

/// Sends feature reports to the receiver's control interface and records every input report received.
public final class HIDTransport: Transport {
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    public private(set) var received: [[UInt8]] = []
    public var onInput: (([UInt8]) -> Void)?

    public private(set) var connection: AulaConnection = .dongle

    /// Picks the receiver first, then the USB cable. Bluetooth is NOT handled here: over BLE macOS exposes only a keyboard/mouse HID
    /// composite with no 64-byte feature report, so `BLETransport` (GATT 0xFEE3/0xFEE4) is used instead.
    public init(candidates: [AulaConnection] = [.dongle, .wired]) throws {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = candidates.map { [kIOHIDVendorIDKey: $0.vendorID, kIOHIDProductIDKey: $0.productID] }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { throw HIDError.controlInterfaceNotFound }
        func feature(_ d: IOHIDDevice) -> Int {
            (IOHIDDeviceGetProperty(d, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int) ?? 0
        }
        func ids(_ d: IOHIDDevice) -> (Int, Int) {
            ((IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int) ?? 0,
             (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int) ?? 0)
        }
        var chosen: (IOHIDDevice, AulaConnection)?
        for c in candidates {
            let ofKind = set.filter { ids($0) == (c.vendorID, c.productID) }
            if let d = ofKind.first(where: { feature($0) == 64 }) ?? ofKind.first(where: { feature($0) > 0 }) {
                chosen = (d, c); break
            }
        }
        guard let (dev, kind) = chosen else { throw HIDError.controlInterfaceNotFound }
        device = dev
        connection = kind
        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { throw HIDError.openFailed(r) }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 256, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let me = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
            _ = reportID  // IOKit already puts the report ID in byte 0 of `report` for numbered reports
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            me.received.append(bytes)
            me.onInput?(bytes)
        }, ctx)
    }

    deinit {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        inputBuffer.deallocate()
    }

    /// `packet[0]` is the report ID; all 64 bytes are sent as-is (how hidapi sends numbered feature reports).
    public func send(_ packet: [UInt8]) throws {
        let r = packet.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(packet[0]), $0.baseAddress!, packet.count)
        }
        guard r == kIOReturnSuccess else { throw HIDError.sendFailed(r) }
    }

    /// Sends, then waits for the ack event (0x50) for the same report ID. Retries up to `attempts` times.
    /// The battery level (%) is delivered through `onInput` if a status event arrives while waiting.
    @discardableResult
    public func sendAwaitingAck(_ packet: [UInt8], attempts: Int = 3, wait: Double = 0.7) throws -> Bool {
        for _ in 0..<attempts {
            let mark = received.count
            try send(packet)
            let deadline = Date().addingTimeInterval(wait)
            while Date() < deadline {
                listen(seconds: 0.05)
                for r in received[mark...] {
                    if case let .ack(ok, id)? = DeviceEvent.parse(r), id == packet[0] { return ok }
                }
            }
        }
        return false
    }

    /// Uploads one logical macro packet: sends 3 chunks spaced apart, then waits for the ack of report 0x09 (retries up to `attempts` times).
    @discardableResult
    public func sendMacroPacket(_ logical: [UInt8], attempts: Int = 3) throws -> Bool {
        let chunks = MacroEncoder.chunks(logical)
        for _ in 0..<attempts {
            let mark = received.count
            for c in chunks { try send(c); listen(seconds: 0.3) }
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                listen(seconds: 0.05)
                for r in received[mark...] {
                    if case let .ack(ok, id)? = DeviceEvent.parse(r), id == 0x09 { return ok }
                }
            }
        }
        return false
    }

    /// Runs the run loop for `seconds` seconds to receive input reports.
    public func listen(seconds: Double) {
        CFRunLoopRunInMode(.defaultMode, seconds, false)
    }
}
