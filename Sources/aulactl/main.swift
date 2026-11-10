import AulaKit
import Foundation

nonisolated(unsafe) var keepAliveBLE: BLETransport?

/// Bluetooth mouse that is already connected first (the mouse is in one mode at a time, so a plugged-in receiver would be
/// silent), then the 2.4G receiver / USB cable, then a Bluetooth scan.
func openLink() throws -> any MouseLink {
    func openBLE(scan: Bool) -> Result<BLETransport, Error> {
        var result: Result<BLETransport, Error>?
        keepAliveBLE = BLETransport.open(timeout: scan ? 12 : 5, scan: scan) { result = $0 }
        while result == nil { CFRunLoopRunInMode(.defaultMode, 0.05, false) }
        return result!
    }
    if case .success(let b) = openBLE(scan: false) { return b }
    if let t = try? HIDTransport() { return t }
    return try openBLE(scan: true).get()
}

let args = CommandLine.arguments.dropFirst()
switch args.first ?? "list" {
case "list":
    var found = false
    for c in AulaConnection.allCases {
        let items = HIDDevices.list(vendorID: c.vendorID, productID: c.productID)
        guard !items.isEmpty else { continue }
        found = true
        print("== \(c.title) (VID 0x\(String(c.vendorID, radix: 16)) PID 0x\(String(c.productID, radix: 16)))")
        for i in items {
            print(String(format: "  %@  usagePage=0x%04X usage=0x%02X  in=%d out=%d feature=%d  %@",
                         i.product, i.usagePage, i.usage,
                         i.maxInputReportSize, i.maxOutputReportSize, i.maxFeatureReportSize, i.transport))
            if args.contains("-v") { print("    descriptor:", hex(i.reportDescriptor)) }
        }
    }
    if !found { print("No AULA SC650 device found (dongle, wired or Bluetooth)."); exit(1) }
case "send-rate":
    // Test approved by the user: sends packet 0x06 (polling rate), then listens for the reply.
    guard let hz = args.dropFirst().first.flatMap({ Int($0) }).flatMap(PollingRate.init(rawValue:)) else {
        print("Usage: aulactl send-rate 125|250|500|1000"); exit(2)
    }
    do {
        let t = try openLink()
        guard t.supportsPollingRate else { print("Polling rate is not available over Bluetooth."); exit(3) }
        t.onInput = { print("  <- input:", hex($0)) }
        let pkt = PacketBuilder.pollingRate(hz)
        print("-> sending (\(hz) Hz):", hex(Array(pkt.prefix(12))), "…")
        let ok = try t.sendAwaitingAck(pkt)
        t.listen(seconds: 1)
        print(ok ? "ACK received" : "no ACK received")
        for r in t.received { print("  ", DeviceEvent.parse(r).map { "\($0)" } ?? hex(r)) }
    } catch { print("Error:", error); exit(1) }
case "send-light":
    // aulactl send-light <mode 0-11> [brightness 1-8] [speed 4-8]
    let a = args.dropFirst().compactMap { Int($0) }
    var l = LightSettings()
    if let m = a.first.flatMap(LightMode.init(rawValue:)) { l.mode = m }
    if a.count > 1 { l.brightness = min(8, max(1, a[1])) }
    if a.count > 2 { l.speed = min(8, max(4, a[2])) }
    do {
        let t = try openLink()
        let pkt = PacketBuilder.lighting(l)
        print("-> 0x05 (\(l.mode.title)):", hex(Array(pkt.prefix(13))))
        if ProcessInfo.processInfo.environment["AULA_PRE0C"] != nil {
            var c = [UInt8](repeating: 0, count: 64)
            c.replaceSubrange(0..<6, with: [0x0C, 0x0A, 0x01, 0xFE, 0x01, 0xFE])
            let ok0 = try t.sendAwaitingAck(c, attempts: 2, wait: 1.0)
            print("0x0C:", ok0 ? "ACK" : "no ACK")
        }
        let len = ProcessInfo.processInfo.environment["AULA_LEN"].flatMap { Int($0) } ?? 64
        let tries = ProcessInfo.processInfo.environment["AULA_ATTEMPTS"].flatMap { Int($0) } ?? 3
        let ok = try t.sendAwaitingAck(Array(pkt.prefix(len)), attempts: tries, wait: 1.0)
        t.listen(seconds: 0.5)
        print(ok ? "ACK received" : "no ACK received")
        for r in t.received { print("  ", DeviceEvent.parse(r).map { "\($0)" } ?? hex(r)) }
        exit(ok ? 0 : 1)
    } catch { print("Error:", error); exit(1) }
case "send-dpi":
    // Sends the vendor's default DPI profile: 800, 1600, 2400, 3200, 6400, 12000 (last two levels off), current level = 2.
    let palette: [RGB] = [RGB(255, 0, 0), RGB(0, 255, 0), RGB(0, 0, 255), RGB(255, 255, 0),
                          RGB(0, 255, 255), RGB(255, 0, 255), RGB(255, 64, 0), RGB(255, 255, 255)]
    let dpis = [800, 1600, 2400, 3200, 6400, 12000, 800, 800]
    let levels = (0..<8).map { DPILevel(dpi: dpis[$0], color: palette[$0], enabled: $0 < 6) }
    do {
        let t = try openLink()
        let pkt = PacketBuilder.dpiProfile(levels: levels, current: 1)
        print("-> 0x04:", hex(Array(pkt.prefix(52))))
        let ok = try t.sendAwaitingAck(pkt, attempts: 3, wait: 1.0)
        t.listen(seconds: 0.5)
        print(ok ? "ACK received" : "no ACK received")
        for r in t.received { print("  ", DeviceEvent.parse(r).map { "\($0)" } ?? hex(r)) }
        exit(ok ? 0 : 1)
    } catch { print("Error:", error); exit(1) }
case "send-buttons":
    // Sends the vendor's default button table (restores the original behavior).
    do {
        let t = try openLink()
        let pkt = PacketBuilder.buttons(ButtonSlots.defaults)
        print("-> 0x08:", hex(Array(pkt.prefix(64))))
        let ok = try t.sendAwaitingAck(pkt, attempts: 3, wait: 1.0)
        t.listen(seconds: 0.5)
        print(ok ? "ACK received" : "no ACK received")
        for r in t.received { print("  ", DeviceEvent.parse(r).map { "\($0)" } ?? hex(r)) }
        exit(ok ? 0 : 1)
    } catch { print("Error:", error); exit(1) }
case "send-macro":
    // Writes a type-text macro into slot 0 (not assigned to any button).
    let text = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "hello"
    do {
        let t = try openLink()
        var allOK = true
        for logical in MacroEncoder.logicalPackets(Macro.typing(text), startSeq: 0) {
            let ok = try t.sendMacroPacket(logical, attempts: 3)
            print("macro packet:", ok ? "ACK" : "no ACK")
            allOK = allOK && ok
        }
        t.listen(seconds: 0.5)
        for r in t.received { print("  ", DeviceEvent.parse(r).map { "\($0)" } ?? hex(r)) }
        exit(allOK ? 0 : 1)
    } catch { print("Error:", error); exit(1) }
default:
    print("Usage: aulactl list | send-rate <hz> | send-light <mode> [brightness] [speed] | send-dpi | send-buttons | send-macro <text>")
    exit(2)
}
