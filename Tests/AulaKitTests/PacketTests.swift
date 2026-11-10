import XCTest
@testable import AulaKit

final class PacketTests: XCTestCase {
    func testPollingRatePacket() {
        let p = PacketBuilder.pollingRate(.hz1000)
        XCTAssertEqual(p.count, 64)
        XCTAssertEqual(Array(p[0...4]), [0x06, 0x09, 0x01, 0x01, 0xFE])
    }
    func testDPIPacketLayout() {
        let levels = (0..<8).map { DPILevel(dpi: 800 * ($0 + 1) / 2, color: RGB(UInt8($0), 2, 3)) }
        let p = PacketBuilder.dpiProfile(levels: levels, current: 2)
        XCTAssertEqual(Array(p[0...2]), [0x04, 0x38, 0x01])
        XCTAssertEqual(p[24], 3)
        XCTAssertEqual(p[5], 0xFF)
        XCTAssertEqual(Int(p[8]) | Int(p[16]) << 8, 400)
        let sum = p[3...49].reduce(0) { $0 + Int($1) }
        XCTAssertEqual(Int(p[50]) << 8 | Int(p[51]), sum)
    }

    func testEventParsing() {
        XCTAssertEqual(DeviceEvent.parse([0x03, 0x8E, 0x50, 0x00, 0x06]), .ack(success: true, reportID: 6))
        XCTAssertEqual(DeviceEvent.parse([0x03, 0x8E, 0x40, 0x01, 0x61]), .status(wired: false, charged: false, battery: 97))
        XCTAssertEqual(DeviceEvent.parse([0x03, 0x8E, 0x10, 0x03, 0x00]), .dpiLevelChanged(index: 2))
        XCTAssertEqual(DeviceEvent.parse([0x03, 0x8E, 0x20, 0x08, 0x00]), .pollingRateChanged(.hz125))
        XCTAssertNil(DeviceEvent.parse([0x01, 0x02]))
    }

    func testLightingPacketDefaultsMatchVendorLayout() {
        let p = PacketBuilder.lighting(LightSettings())
        XCTAssertEqual(Array(p[0...2]), [0x05, 0x0F, 0x01])
        XCTAssertEqual(p[3], 0x70)               // mode 7 << 4
        XCTAssertEqual(p[4], 0x03)               // 9 - 6, light-off 10 has high nibble = 0
        XCTAssertEqual(p[5], 0xA8)               // low nibble of 10 << 4 | fixed brightness 8
        XCTAssertEqual(Array(p[6...8]), [0, 255, 0])
        XCTAssertEqual(p[9], 1); XCTAssertEqual(p[10], 4)
        let sum = p[3...10].reduce(0) { $0 + Int($1) }
        XCTAssertEqual(Int(p[11]) << 8 | Int(p[12]), sum)
    }
    func testLightOffSplitAcrossNibbles() {
        var l = LightSettings(); l.lightOffMinutes = 60
        let p = PacketBuilder.lighting(l)
        XCTAssertEqual(p[4] & 0xF0, 0x30); XCTAssertEqual(p[5] >> 4, 0x0C)
    }

    func testDefaultButtonPacket() {
        let p = PacketBuilder.buttons(ButtonSlots.defaults)
        XCTAssertEqual(Array(p[0...2]), [0x08, 0x3B, 0x01])
        XCTAssertEqual(Array(p[3...5]), [0x02, 0x00, 0x00])   // id 1 (left click) -> vendor table
        XCTAssertEqual(p[3 + 17 * 3], 0x09)                   // id 11 (scroll up)
        let sum = p[3...56].reduce(0) { $0 + Int($1) }
        XCTAssertEqual(Int(p[57]) << 8 | Int(p[58]), sum)
    }
    func testCustomShortcut() {
        var a = ButtonSlots.defaults
        a[6] = .custom(modifiers: 0x08, key: 0x06)   // Cmd+C
        let p = PacketBuilder.buttons(a)
        XCTAssertEqual(Array(p[21...23]), [0x11, 0x08, 0x06])
    }

    func testMacroEncodingShortAndLongDelays() {
        let m = Macro(name: "t", events: [MacroEvent(key: 0x04, isDown: true, delay: 10),
                                          MacroEvent(key: 0x04, isDown: false, delay: 250)])
        let p = MacroEncoder.logicalPackets(m, startSeq: 0)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].count, 131)
        XCTAssertEqual(Array(p[0][0...2]), [0x09, 0x83, 0x00])
        XCTAssertEqual(Array(p[0][29...32]), [0x0A, 0x04, 0xB2, 0x04])      // down 10ms; up (250 % 100 = 50 -> 0x32|0x80)
    }
    func testMacroSplitsAcrossPackets() {
        let m = Macro.typing(String(repeating: "a", count: 40))             // 80 events, 2 bytes each
        let p = MacroEncoder.logicalPackets(m, startSeq: 3)
        XCTAssertGreaterThan(p.count, 1)
        XCTAssertEqual(p[0][2], 3); XCTAssertEqual(p[1][2], 4)
        XCTAssertTrue(p[0].contains(0xFE))
        let sum = p[0][3...128].reduce(0) { $0 + Int($1) }
        XCTAssertEqual(Int(p[0][129]) << 8 | Int(p[0][130]), sum)
    }
    func testMacroChunks() {
        let p = MacroEncoder.logicalPackets(Macro.typing("ab"), startSeq: 0)[0]
        let c = MacroEncoder.chunks(p)
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(Array(c[0][0...3]), [0x09, 0x40, 0x00, 0x00])
        XCTAssertEqual(Array(c[2][0...3]), [0x09, 0x0C, 0x00, 0x02])
        XCTAssertEqual(c[0][4], p[3])
    }
    func testMacroButtonWire() {
        var a = ButtonSlots.defaults; a[0] = .macro(slot: 2)
        XCTAssertEqual(Array(PacketBuilder.buttons(a)[3...5]), [0x12, 0x00, 0x02])
    }

    func testBluetoothNotificationIsNormalizedToReceiverReport() {
        // BLE: [8E, 50, 00, 05] = ack of report 5; the receiver sends the same with a leading 03.
        let ble: [UInt8] = [0x8E, 0x50, 0x00, 0x05]
        XCTAssertEqual(DeviceEvent.normalizeBLE(ble), [0x03, 0x8E, 0x50, 0x00, 0x05])
        XCTAssertEqual(DeviceEvent.parse(DeviceEvent.normalizeBLE(ble)), .ack(success: true, reportID: 5))
        XCTAssertEqual(DeviceEvent.parse(DeviceEvent.normalizeBLE([0x8E, 0x40, 0x01, 61])), .status(wired: false, charged: false, battery: 61))
        // A report that already has the report ID is left alone.
        let rx: [UInt8] = [0x03, 0x8E, 0x10, 0x03, 0x00]
        XCTAssertEqual(DeviceEvent.normalizeBLE(rx), rx)
        XCTAssertEqual(DeviceEvent.parse(rx), .dpiLevelChanged(index: 2))
    }
}
