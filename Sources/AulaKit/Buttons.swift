import Foundation

/// Action of one button: a built-in function (vendor id), a custom key combination, or a macro.
public enum ButtonAction: Equatable, Codable, Sendable {
    case builtin(Int)
    /// `modifiers`: bit 1 = Ctrl, 2 = Shift, 4 = Alt, 8 = Win/Cmd. `key`: keyboard HID usage code.
    case custom(modifiers: UInt8, key: UInt8)
    /// Macro already uploaded to the mouse, starting at packet number `slot`.
    case macro(slot: Int)

    var wire: [UInt8] {
        switch self {
        case .builtin(let id): return ButtonFunction.rawWire[id] ?? [0x01, 0, 0]
        case .custom(let m, let k): return [0x11, m, k]
        case .macro(let slot): return [0x12, 0x00, UInt8(truncatingIfNeeded: slot)]
        }
    }
}

public enum ButtonSlots {
    /// 18 slots in the profile; defaults follow the table in Mouse.exe (DAT_0041E9C0).
    public static let defaultIDs: [Int] = [1, 2, 3, 6, 6, 121, 5, 4, 121, 0, 0, 0, 0, 0, 0, 0, 12, 11]
    /// Slots for the physical buttons shown in the original UI: left, right, middle, DPI, back, forward.
    public static let physical: [(slot: Int, title: String)] = [
        (0, "Left Click"), (1, "Right Click"), (2, "Middle Click"), (3, "DPI Button"), (6, "Back Button"), (7, "Forward Button"),
    ]
    public static var defaults: [ButtonAction] { defaultIDs.map { .builtin($0) } }
}

public extension PacketBuilder {
    /// 0x08 — assigns 18 buttons. Each entry is 3 bytes from offset 3; 16-bit checksum of bytes 3...56 at offset 57 (high) and 58 (low).
    static func buttons(_ actions: [ButtonAction]) -> [UInt8] {
        precondition(actions.count == 18, "exactly 18 button slots are required")
        var p = [UInt8](repeating: 0, count: size)
        p[0] = 0x08; p[1] = 0x3B; p[2] = 0x01
        for (i, a) in actions.enumerated() {
            let w = a.wire
            p[3 + i * 3] = w[0]; p[4 + i * 3] = w[1]; p[5 + i * 3] = w[2]
        }
        let sum = p[3...56].reduce(0) { $0 + Int($1) }
        p[57] = UInt8((sum >> 8) & 0xFF)
        p[58] = UInt8(sum & 0xFF)
        return p
    }
}
