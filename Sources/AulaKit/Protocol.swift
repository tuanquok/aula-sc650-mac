import Foundation

/// 64-byte feature report packets. See docs/PROTOCOL.md; fields not yet verified are marked (?).
public enum PollingRate: Int, CaseIterable, Codable, Sendable {
    case hz125 = 125, hz250 = 250, hz500 = 500, hz1000 = 1000

    /// Byte value in packet 0x06 (interval in ms) (?).
    var code: UInt8 {
        switch self {
        case .hz125: return 8
        case .hz250: return 4
        case .hz500: return 2
        case .hz1000: return 1
        }
    }
}

public struct RGB: Equatable, Codable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
}

public struct DPILevel: Equatable, Codable, Sendable {
    public var dpi: Int          // 50...12000 per the code table in Mouse.exe
    public var color: RGB
    public var enabled: Bool
    public init(dpi: Int, color: RGB, enabled: Bool = true) {
        self.dpi = dpi; self.color = color; self.enabled = enabled
    }

    /// Vendor DPI code (formula reverse-engineered from Mouse.exe 0x414E30), (?) for the range above 10000.
    var vendorCode: Int {
        dpi <= 10000 ? max(1, dpi / 50) : dpi / 100 + 100
    }
}

public enum LightMode: Int, CaseIterable, Codable, Sendable {
    case off = 0, staticColor, breathing, neon, colorBreathing, colorStatic, mixedBreathing,
         rainbowWave, lightning, staticMixed, marquee, marquee2

    public var title: String {
        ["Off", "Static", "Breathing", "Neon", "Color Breathing", "Fixed Color", "Mixed Breathing",
         "Rainbow Wave", "Lightning", "Mixed Static", "Marquee", "Marquee 2"][rawValue]
    }
    /// Only these two modes use the user-selected brightness (Mouse.exe 0x414AA0); the other modes are fixed at 8.
    var usesBrightness: Bool { self == .staticColor || self == .staticMixed }
}

/// Settings sent in packet 0x05 (lighting + power + button debounce). Value ranges come from the original UI's XML.
public struct LightSettings: Equatable, Codable, Sendable {
    public var mode: LightMode = .rainbowWave   // vendor default: 7
    public var brightness = 8                   // 1...8
    public var speed = 6                        // 4...8
    public var color = RGB(0, 255, 0)           // vendor default 0xFF00 -> (00,FF,00)
    public var lightOffMinutes = 10             // 1...60
    public var sleepMinutes = 1                 // 1...60
    public var debounce = 4                     // 2...25
    public init() {}
}

public enum PacketBuilder {
    public static let size = 64

    /// 0x06 — polling rate.
    public static func pollingRate(_ rate: PollingRate) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: size)
        p[0] = 0x06; p[1] = 0x09; p[2] = 0x01
        p[3] = rate.code
        p[4] = ~rate.code
        return p
    }

    /// 0x04 — 8 DPI levels + colors + current level. Checksum (?): 16-bit sum of bytes 3...49 (big-endian at 50, 51).
    /// `angleSnap` -> profile[0x944] (byte 3, off by default); `rippleControl` -> profile[0x940] (byte 4, on by default).
    /// (Order inferred from the order the option group is created in Mouse.exe: lift-off, ripple, angle snap.)
    public static func dpiProfile(levels: [DPILevel], current: Int, rippleControl: Bool = true,
                                  angleSnap: Bool = false) -> [UInt8] {
        precondition(levels.count == 8, "exactly 8 DPI levels are required")
        var p = [UInt8](repeating: 0, count: size)
        p[0] = 0x04; p[1] = 0x38; p[2] = 0x01
        p[3] = angleSnap ? 1 : 0
        p[4] = rippleControl ? 1 : 0
        var enabledMask: UInt8 = 0
        var highMask: UInt8 = 0
        for (i, l) in levels.enumerated() {
            if l.enabled { enabledMask |= 1 << UInt8(i) }
            let code = l.vendorCode
            let value: Int
            if code <= 0xC8 { value = code * 50 }
            else {
                var v = (code - 100) * 100
                if code > 0xDC { v /= 2 }
                value = v
            }
            if code >= 0xDD { highMask |= 1 << UInt8(i) }
            p[8 + i] = UInt8(value & 0xFF)
            p[16 + i] = UInt8((value >> 8) & 0xFF)
            p[25 + i * 3] = l.color.r
            p[26 + i * 3] = l.color.g
            p[27 + i * 3] = l.color.b
        }
        p[5] = enabledMask
        p[6] = highMask; p[7] = highMask
        p[24] = UInt8(current + 1)
        p[49] = 0x01
        let sum = p[3...49].reduce(0) { $0 + Int($1) }
        p[50] = UInt8((sum >> 8) & 0xFF)
        p[51] = UInt8(sum & 0xFF)
        return p
    }

    /// 0x05 — lighting, light-off/sleep timers, button debounce. Layout per Mouse.exe 0x414AA0:
    /// checksum = 16-bit sum of bytes 3...10, high byte at 11, low byte at 12.
    public static func lighting(_ l: LightSettings) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: size)
        let mode = UInt8(l.mode.rawValue)
        let off = UInt8(clamping: l.lightOffMinutes)
        let speedInv = UInt8(clamping: 9 - l.speed)
        p[0] = 0x05; p[1] = 0x0F; p[2] = 0x01
        p[3] = (mode & 0x0F) << 4
        p[4] = (off & 0xF0) | speedInv
        p[5] = ((off & 0x0F) << 4) | (l.mode.usesBrightness ? UInt8(clamping: l.brightness) : 8)
        p[6] = l.color.r; p[7] = l.color.g; p[8] = l.color.b
        p[9] = UInt8(clamping: l.sleepMinutes)
        p[10] = UInt8(clamping: l.debounce)
        let sum = p[3...10].reduce(0) { $0 + Int($1) }
        p[11] = UInt8((sum >> 8) & 0xFF)
        p[12] = UInt8(sum & 0xFF)
        return p
    }
}
