import SwiftUI
import AulaKit

@main
struct AulaApp: App {
    @StateObject private var model = MouseModel()
    var body: some Scene {
        WindowGroup("AULA SC650") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

/// Settings are stored locally (the mouse has no read-back command, so the app keeps its own copy).
struct SavedConfig: Codable {
    var levels: [DPILevel]
    var currentLevel: Int
    var rippleControl: Bool
    var angleSnap: Bool
    var polling: PollingRate
    var light: LightSettings
    var buttons: [ButtonAction]
    var macroText: [Int: String]
}

@MainActor
final class MouseModel: ObservableObject {
    @Published var levels: [DPILevel]
    @Published var currentLevel: Int
    @Published var rippleControl: Bool
    @Published var angleSnap: Bool
    @Published var polling: PollingRate
    @Published var light: LightSettings
    @Published var buttons: [ButtonAction]
    @Published var macroText: [Int: String] = [:]

    @Published var deviceFound = false
    @Published var connectionTitle = ""
    @Published var battery: Int?
    @Published var charging = false
    @Published var status = "Nothing sent to the mouse yet."
    @Published var supportsPolling = true
    @Published var applying = false
    @Published var log: [String] = []

    private var transport: (any MouseLink)?
    private var ble: BLETransport?
    private static let key = "aula.sc650.config.v3"

    init() {
        let palette: [RGB] = [RGB(255, 0, 0), RGB(0, 255, 0), RGB(0, 0, 255), RGB(255, 255, 0),
                              RGB(0, 255, 255), RGB(255, 0, 255), RGB(255, 64, 0), RGB(255, 255, 255)]
        // Vendor defaults (800, 1600, 2400, 3200, 6400, 12000; the last two levels are off).
        let codes = [800, 1600, 2400, 3200, 6400, 12000, 800, 800]
        let def = SavedConfig(
            levels: (0..<8).map { DPILevel(dpi: codes[$0], color: palette[$0], enabled: $0 < 6) },
            currentLevel: 1, rippleControl: true, angleSnap: false, polling: .hz500, light: LightSettings(),
            buttons: ButtonSlots.defaults, macroText: [:])
        var cfg = def
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(SavedConfig.self, from: data),
           saved.levels.count == 8, saved.buttons.count == 18 { cfg = saved }
        levels = cfg.levels; currentLevel = cfg.currentLevel; rippleControl = cfg.rippleControl; angleSnap = cfg.angleSnap
        polling = cfg.polling; light = cfg.light; buttons = cfg.buttons; macroText = cfg.macroText
        connect()
    }

    /// The mouse is in exactly one mode at a time. If it is already connected over Bluetooth, that is the live link:
    /// a receiver left plugged in would be silent and every packet would go unanswered. So: connected Bluetooth mouse first,
    /// then the 2.4G receiver / USB cable, and finally a Bluetooth scan.
    func connect() {
        ble?.close(); ble = nil
        transport = nil
        deviceFound = false
        status = "Looking for the mouse…"
        ble = BLETransport.open(timeout: 5, scan: false) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let b): self.adoptBluetooth(b)
            case .failure:
                if let t = try? HIDTransport() { self.attach(t); return }
                self.status = "Looking for the mouse over Bluetooth…"
                self.ble = BLETransport.open { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let b): self.adoptBluetooth(b)
                    case .failure(let e): self.deviceFound = false; self.status = "\(e)"
                    }
                }
            }
        }
    }

    private func adoptBluetooth(_ b: BLETransport) {
        b.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.deviceFound = false; self?.transport = nil
                self?.status = "Bluetooth connection lost. Press refresh to reconnect."
            }
        }
        attach(b)
    }

    private func attach(_ link: any MouseLink) {
        link.onInput = { [weak self] r in
            guard let ev = DeviceEvent.parse(r) else { return }
            Task { @MainActor in self?.handle(ev) }
        }
        transport = link
        deviceFound = true
        connectionTitle = link.connectionTitle
        supportsPolling = link.supportsPollingRate
        status = "Connected via \(link.connectionTitle)."
        // Test hook: `--apply=light|dpi|buttons|polling` applies that group once, right after connecting.
        if let g = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--apply=") })?.dropFirst(8) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.apply(groups: [String(g)])
            }
        }
    }

    private func handle(_ ev: DeviceEvent) {
        switch ev {
        case .status(_, let charged, let pct): battery = pct; charging = charged
        case .dpiLevelChanged(let i): currentLevel = i
        case .pollingRateChanged(let r): polling = r
        default: break
        }
    }

    private func save() {
        let cfg = SavedConfig(levels: levels, currentLevel: currentLevel, rippleControl: rippleControl, angleSnap: angleSnap,
                              polling: polling, light: light, buttons: buttons, macroText: macroText)
        if let d = try? JSONEncoder().encode(cfg) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    /// Sends the packets one by one, waiting for the mouse to acknowledge each. Stops at the first failure.
    func apply(groups: Set<String> = ["dpi", "polling", "light", "buttons"]) {
        guard let t = transport else { status = "Not connected."; return }
        save()
        applying = true; log = []
        var packets: [(String, [UInt8])] = []
        if groups.contains("dpi") {
            packets.append(("DPI (0x04)", PacketBuilder.dpiProfile(levels: levels, current: currentLevel, rippleControl: rippleControl, angleSnap: angleSnap)))
        }
        if groups.contains("polling") {
            if t.supportsPollingRate { packets.append(("Polling rate (0x06)", PacketBuilder.pollingRate(polling))) }
            else { log.append("– Polling rate (not available over Bluetooth)") }
        }
        if groups.contains("light") { packets.append(("Lighting / power (0x05)", PacketBuilder.lighting(light))) }
        var allOK = true
        var resolved = buttons
        if groups.contains("buttons") {
            // Upload macros first (slots allocated sequentially from 0), then send the button table.
            var seq = 0
            for item in ButtonSlots.physical {
                guard case .macro = buttons[item.slot] else { continue }
                let macro = Macro.typing(macroText[item.slot] ?? "")
                guard !macro.events.isEmpty else { resolved[item.slot] = .builtin(0); continue }
                let logical = MacroEncoder.logicalPackets(macro, startSeq: seq)
                for lp in logical {
                    do {
                        let ok = try t.sendMacroPacket(lp)
                        log.append("\(ok ? "✓" : "✗") Macro \(item.title) (0x09 #\(lp[2]))")
                        if !ok { allOK = false }
                    } catch { log.append("✗ Macro: \(error)"); allOK = false }
                    if !allOK { break }
                }
                if !allOK { break }
                resolved[item.slot] = .macro(slot: seq)
                seq += logical.count
            }
            packets.append(("Buttons (0x08)", PacketBuilder.buttons(resolved)))
        }
        for (name, pkt) in packets {
            do {
                let ok = try t.sendAwaitingAck(pkt)
                log.append("\(ok ? "✓" : "✗") \(name)")
                if !ok { allOK = false; break }
            } catch {
                log.append("✗ \(name): \(error)"); allOK = false; break
            }
        }
        status = allOK ? "Applied. The mouse acknowledged every packet." : "Some packets were not acknowledged by the mouse."
        applying = false
    }

    func resetButtons() { buttons = ButtonSlots.defaults }
}
