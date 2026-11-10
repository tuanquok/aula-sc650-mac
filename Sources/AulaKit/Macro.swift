import Foundation

/// Key event in a macro. `delay` (ms) is the vendor's delay field (1 ms units; >=128 is encoded in hundreds of ms).
public struct MacroEvent: Equatable, Codable, Sendable {
    public var key: UInt8        // keyboard HID usage code
    public var isDown: Bool      // true = press, false = release
    public var delay: Int
    public init(key: UInt8, isDown: Bool, delay: Int) { self.key = key; self.isDown = isDown; self.delay = delay }
}

public struct Macro: Equatable, Codable, Sendable {
    public var name: String
    public var events: [MacroEvent]
    public init(name: String, events: [MacroEvent]) { self.name = name; self.events = events }

    /// "Type text" macro: presses then releases each character (lowercase a-z, 0-9, space), `delay` ms apart.
    public static func typing(_ text: String, delay: Int = 10) -> Macro {
        var ev: [MacroEvent] = []
        for ch in text.lowercased() {
            guard let k = HIDKeyCodes.code(for: ch) else { continue }
            ev.append(MacroEvent(key: k, isDown: true, delay: delay))
            ev.append(MacroEvent(key: k, isDown: false, delay: delay))
        }
        return Macro(name: text, events: ev)
    }
}

public enum HIDKeyCodes {
    public static func code(for c: Character) -> UInt8? {
        guard let a = c.asciiValue else { return nil }
        switch a {
        case 97...122: return UInt8(0x04 + a - 97)           // a-z
        case 49...57: return UInt8(0x1E + a - 49)            // 1-9
        case 48: return 0x27                                  // 0
        case 32: return 0x2C                                  // space
        default: return nil
        }
    }
}

/// Encodes a macro into 131-byte logical packets (packet 0x09), split into 3 x 64-byte feature reports on the receiver (written whole over Bluetooth).
/// Layout per Mouse.exe 0x4151B0 / 0x414390. The mouse acknowledges the upload; header byte semantics are only partly decoded.
public enum MacroEncoder {
    public static let logicalSize = 0x83            // 131
    static let eventsStart = 29
    static let eventsLimit = 0x62                   // at most 98 event bytes per packet

    /// `startSeq`: sequence number of the first packet (also the "slot" used in the button assignment).
    public static func logicalPackets(_ macro: Macro, startSeq: Int) -> [[UInt8]] {
        var packets: [[UInt8]] = []
        var index = 0
        var seq = startSeq
        repeat {
            var p = [UInt8](repeating: 0, count: logicalSize)
            p[0] = 0x09; p[1] = 0x83; p[2] = UInt8(truncatingIfNeeded: seq)
            if index == 0 { p[7] = 1 }     // default header: bytes 3..6 = 0, byte 7 = max(1, vendor value)
            var used = 0
            var slots = 0
            var overflow = false
            while index < macro.events.count {
                let e = macro.events[index]
                var bytes: [UInt8]
                var weight: Int
                if e.delay < 0x80 {
                    let d = UInt8(max(e.delay, 2))
                    bytes = [e.isDown ? d : d | 0x80, e.key]; weight = 1
                } else {
                    let d = UInt8(max(e.delay % 100, 2))
                    bytes = [e.isDown ? d : d | 0x80, e.key, UInt8(truncatingIfNeeded: e.delay / 100), 3]; weight = 2
                }
                if used + bytes.count > eventsLimit { overflow = true; break }
                for (i, b) in bytes.enumerated() { p[eventsStart + used + i] = b }
                used += bytes.count; slots += weight; index += 1
            }
            if overflow {
                p[eventsStart + used] = UInt8(truncatingIfNeeded: seq + 1)   // continuation marker to the next packet
                p[eventsStart + used + 1] = 0xFE
            }
            p[28] = UInt8(slots)
            let sum = p[3...128].reduce(0) { $0 + Int($1) }
            p[129] = UInt8((sum >> 8) & 0xFF); p[130] = UInt8(sum & 0xFF)
            packets.append(p)
            seq += 1
        } while index < macro.events.count
        return packets
    }

    /// Splits the logical packet into 3 feature reports `[09, 40|0C, seq, idx, 60 bytes]`.
    public static func chunks(_ logical: [UInt8]) -> [[UInt8]] {
        (0..<3).map { i in
            var c = [UInt8](repeating: 0, count: 64)
            c[0] = 0x09; c[1] = (i == 2) ? 0x0C : 0x40; c[2] = logical[2]; c[3] = UInt8(i)
            let from = 3 + i * 60
            let to = min(from + 60, logical.count)
            if from < to { c.replaceSubrange(4..<(4 + to - from), with: logical[from..<to]) }
            return c
        }
    }
}
