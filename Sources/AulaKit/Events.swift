import Foundation

/// 5-byte input report from the receiver: `[03, 8E, kind, b3, b4]` (decoded per Mouse.exe FUN_00413b80).
public enum DeviceEvent: Equatable, Sendable {
    case dpiLevelChanged(index: Int)           // 0x10: b3 = level (1...8)
    case pollingRateChanged(PollingRate)       // 0x20: b3 = 1/2/4/8
    case ack(success: Bool, reportID: UInt8)   // 0x50: b3 == 0 means success; b4 echoes the report ID (observed)
    case status(wired: Bool, charged: Bool, battery: Int) // 0x40: b3 (1 = wireless, 2 = fully charged), b4 = battery %
    case unknown(kind: UInt8, b3: UInt8, b4: UInt8)

    /// Bluetooth LE notifications (characteristic 0xFEE4) are the same event without the leading report ID: `[8E, kind, b3, b4]`.
    /// Returns the 5-byte receiver-style report so that `parse` handles both.
    public static func normalizeBLE(_ bytes: [UInt8]) -> [UInt8] {
        (bytes.count >= 4 && bytes[0] == 0x8E) ? [0x03] + bytes : bytes
    }

    /// `report` includes the report ID at byte 0, as IOKit returns it.
    public static func parse(_ report: [UInt8]) -> DeviceEvent? {
        guard report.count >= 5, report[0] == 0x03, report[1] == 0x8E else { return nil }
        let kind = report[2], b3 = report[3], b4 = report[4]
        switch kind {
        case 0x10 where (1...8).contains(Int(b3)):
            return .dpiLevelChanged(index: Int(b3) - 1)
        case 0x20:
            switch b3 {
            case 8: return .pollingRateChanged(.hz125)
            case 4: return .pollingRateChanged(.hz250)
            case 2: return .pollingRateChanged(.hz500)
            case 1: return .pollingRateChanged(.hz1000)
            default: return .unknown(kind: kind, b3: b3, b4: b4)
            }
        case 0x50: return .ack(success: b3 == 0, reportID: b4)
        case 0x40: return .status(wired: b3 != 1, charged: b3 == 2, battery: Int(b4))
        default: return .unknown(kind: kind, b3: b3, b4: b4)
        }
    }
}
