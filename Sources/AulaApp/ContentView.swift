import SwiftUI
import AulaKit

enum Tab: String, CaseIterable, Identifiable {
    case dpi = "DPI", buttons = "BUTTONS", light = "LIGHTING", system = "SYSTEM"
    var id: String { rawValue }
    /// Packet groups sent when Apply is pressed on this tab.
    var groups: Set<String> {
        switch self {
        case .dpi: ["dpi"]
        case .buttons: ["buttons"]
        case .light: ["light"]
        case .system: ["polling", "light", "dpi"]
        }
    }
    var icon: String {
        switch self { case .dpi: "scope"; case .buttons: "computermouse"; case .light: "lightbulb.led.fill"; case .system: "slider.horizontal.3" }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: MouseModel
    /// `--tab=buttons|lighting|system` opens that tab at launch (handy for screenshots).
    @State private var tab: Tab = {
        let arg = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--tab=") }?.dropFirst(6).uppercased()
        return Tab.allCases.first { $0.rawValue == arg } ?? .dpi
    }()

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            HStack(spacing: 0) {
                sidebar
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ScrollView { content.padding(.trailing, 4) }
                    footer
                }
                .padding(26)
            }
        }
    }

    var sidebar: some View {
        VStack(spacing: 6) {
            Text("AULA").font(.system(size: 22, weight: .black, design: .rounded)).foregroundStyle(Theme.accent)
                .padding(.top, 34).padding(.bottom, 20)
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.icon).frame(width: 18)
                        Text(t.rawValue).font(.system(size: 12, weight: .heavy, design: .monospaced)).tracking(1.5)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .foregroundStyle(tab == t ? .white : Theme.muted)
                    .background(RoundedRectangle(cornerRadius: 10).fill(tab == t ? Theme.accent.opacity(0.85) : .clear))
                    .shadow(color: tab == t ? Theme.accent.opacity(0.5) : .clear, radius: 10)
                }.buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12).frame(width: 170)
        .background(Color.black.opacity(0.35))
    }

    var header: some View {
        HStack(spacing: 14) {
            Text("SC650").font(.system(size: 28, weight: .light, design: .rounded)).foregroundStyle(Theme.text)
            Spacer()
            if let b = model.battery {
                HStack(spacing: 6) {
                    Image(systemName: model.charging ? "battery.100.bolt" : "battery.75")
                    Text("\(b)%").font(.system(size: 12, weight: .heavy, design: .monospaced))
                }.foregroundStyle(b > 20 ? Theme.accent2 : .orange)
            }
            Circle().fill(model.deviceFound ? Color.green : Color.orange).frame(width: 9, height: 9)
                .shadow(color: model.deviceFound ? .green : .orange, radius: 6)
            Text(model.deviceFound ? "\(model.connectionTitle) connected" : "No device found")
                .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.muted)
            Button("↻") { model.connect() }.buttonStyle(.plain).foregroundStyle(Theme.accent2)
        }
    }

    @ViewBuilder var content: some View {
        switch tab {
        case .dpi: DPIView()
        case .buttons: ButtonsView()
        case .light: LightView()
        case .system: SystemView()
        }
    }

    var footer: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                Text(model.log.joined(separator: "   ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.accent2)
            }
            Spacer()
            Button("APPLY \(tab.rawValue)") { model.apply(groups: tab.groups) }
                .buttonStyle(GamingButtonStyle())
                .disabled(!model.deviceFound || model.applying || !model.hasLeftClick)
                .opacity(model.deviceFound && model.hasLeftClick ? 1 : 0.4)
        }
    }
}

extension MouseModel {
    /// The original app forbids removing every left click: at least one button must be "Left Click".
    var hasLeftClick: Bool { buttons.contains(.builtin(1)) }
}

// MARK: - DPI
struct DPIView: View {
    @EnvironmentObject var model: MouseModel
    var body: some View {
        Panel(title: "DPI Levels") {
            ForEach(model.levels.indices, id: \.self) { i in
                HStack(spacing: 12) {
                    Button { model.currentLevel = i } label: {
                        Circle().strokeBorder(model.currentLevel == i ? Theme.accent : Theme.muted, lineWidth: 2)
                            .background(Circle().fill(model.currentLevel == i ? Theme.accent : .clear))
                            .frame(width: 16, height: 16)
                    }.buttonStyle(.plain)
                    Text(verbatim: String(i + 1)).font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.muted).frame(width: 14)
                    Toggle("", isOn: $model.levels[i].enabled).labelsHidden().toggleStyle(.switch).tint(Theme.accent2)
                    Slider(value: Binding(get: { Double(model.levels[i].dpi) },
                                          set: { model.levels[i].dpi = Self.snap(Int($0)) }),
                           in: 50...12000).tint(Color(rgb: model.levels[i].color))
                    Text(verbatim: String(model.levels[i].dpi)).font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Theme.text).frame(width: 56, alignment: .trailing)
                    ColorPicker("", selection: Binding(get: { Color(rgb: model.levels[i].color) },
                                                       set: { model.levels[i].color = $0.rgb }),
                                supportsOpacity: false).labelsHidden()
                }
                .opacity(model.levels[i].enabled ? 1 : 0.4)
            }
        }
    }
    /// Below 10000: step 50; above that: step 100 (matches the vendor's DPI code table).
    static func snap(_ v: Int) -> Int { v <= 10000 ? max(50, v / 50 * 50) : v / 100 * 100 }
}

// MARK: - Buttons
struct ButtonsView: View {
    @EnvironmentObject var model: MouseModel
    var body: some View {
        Panel(title: "Button Assignment") {
            HStack(alignment: .top, spacing: 22) {
                MouseImage().frame(width: 150, height: 285)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ButtonSlots.physical, id: \.slot) { item in
                        ButtonRow(title: item.title, action: $model.buttons[item.slot], macroText: Binding(get: { model.macroText[item.slot] ?? "" }, set: { model.macroText[item.slot] = $0 }))
                    }
                }
            }
            HStack {
                if !model.hasLeftClick {
                    Text("At least one button must be Left Click.").foregroundStyle(.orange)
                        .font(.system(size: 11, design: .monospaced))
                }
                Spacer()
                Button("Restore Defaults") { model.resetButtons() }.buttonStyle(.plain).foregroundStyle(Theme.accent2)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            Text("Text macros use the 0x09 protocol reverse-engineered from the original app. Shortcuts use Cmd in place of Win.")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
        }
    }
}

/// Product picture taken from the original AULA app (res/skins/ms_1/mouse.png). Shipped in Contents/Resources.
struct MouseImage: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "mouse", withExtension: "png"), let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().scaledToFit()
                .shadow(color: Theme.accent.opacity(0.45), radius: 22)
        } else {
            Image(systemName: "computermouse.fill").resizable().scaledToFit().padding(40).foregroundStyle(Theme.muted)
        }
    }
}

struct ButtonRow: View {
    let title: String
    @Binding var action: ButtonAction
    @Binding var macroText: String
    private let customTag = -1
    private let macroTag = -2

    private var selection: Binding<Int> {
        Binding(get: {
                    switch action { case .builtin(let id): return id; case .custom: return customTag; case .macro: return macroTag }
                },
                set: { v in
                    if v == customTag { action = .custom(modifiers: 0x08, key: 0x06) }
                    else if v == macroTag { action = .macro(slot: 0) }
                    else { action = .builtin(v) }
                })
    }
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                .frame(width: 110, alignment: .leading)
            Picker("", selection: selection) {
                ForEach(ButtonFunction.catalog) { f in Text(f.title).tag(f.id) }
                Divider()
                Text("Custom shortcut…").tag(customTag)
                Text("Type-text macro…").tag(macroTag)
            }.labelsHidden().frame(width: 200)
            if case .custom(let m, let k) = action {
                HStack(spacing: 6) {
                    ForEach([("Ctrl", 1), ("Shift", 2), ("Opt", 4), ("Cmd", 8)], id: \.1) { name, bit in
                        Toggle(name, isOn: Binding(get: { m & UInt8(bit) != 0 },
                                                   set: { on in action = .custom(modifiers: on ? m | UInt8(bit) : m & ~UInt8(bit), key: k) }))
                            .toggleStyle(.button).tint(Theme.accent2)
                    }
                    Picker("", selection: Binding(get: { Int(k) }, set: { action = .custom(modifiers: m, key: UInt8($0)) })) {
                        ForEach(Keys.all, id: \.code) { Text($0.name).tag(Int($0.code)) }
                    }.labelsHidden().frame(width: 100)
                }
            }
            if case .macro = action {
                TextField("text (a-z, 0-9, space)", text: $macroText).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            Spacer()
        }
    }
}

enum Keys {
    static let all: [(name: String, code: UInt8)] = {
        var r: [(String, UInt8)] = []
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { r.append((String(c), UInt8(0x04 + i))) }
        for (i, c) in "1234567890".enumerated() { r.append((String(c), UInt8(0x1E + i))) }
        for i in 1...12 { r.append(("F\(i)", UInt8(0x3A + i - 1))) }
        r += [("Enter", 0x28), ("Esc", 0x29), ("Backspace", 0x2A), ("Tab", 0x2B), ("Space", 0x2C), ("Delete", 0x4C),
              ("Home", 0x4A), ("End", 0x4D), ("PageUp", 0x4B), ("PageDown", 0x4E),
              ("→", 0x4F), ("←", 0x50), ("↓", 0x51), ("↑", 0x52)]
        return r
    }()
}

// MARK: - Light
struct LightView: View {
    @EnvironmentObject var model: MouseModel
    var body: some View {
        Panel(title: "LED Lighting") {
            Picker("Mode", selection: $model.light.mode) {
                ForEach(LightMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).frame(width: 280)
            LabeledSlider(title: "Brightness (Static modes)", value: $model.light.brightness, range: 1...8)
            LabeledSlider(title: "Speed", value: $model.light.speed, range: 4...8)
            HStack {
                Text("Color").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted).frame(width: 160, alignment: .leading)
                ColorPicker("", selection: Binding(get: { Color(rgb: model.light.color) }, set: { model.light.color = $0.rgb }),
                            supportsOpacity: false).labelsHidden()
            }
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var unit = ""
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted).frame(width: 160, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1).tint(Theme.accent)
            Text(verbatim: "\(value)\(unit)").font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundStyle(Theme.text)
                .frame(width: 64, alignment: .trailing)
        }
    }
}

// MARK: - System
struct SystemView: View {
    @EnvironmentObject var model: MouseModel
    var body: some View {
        VStack(spacing: 18) {
            Panel(title: "Polling Rate") {
                if !model.supportsPolling {
                    Text("Polling rate can only be changed through the 2.4G receiver or the USB cable, not over Bluetooth.")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    ForEach(PollingRate.allCases, id: \.self) { r in
                        Button("\(r.rawValue) Hz") { model.polling = r }.buttonStyle(.plain)
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .padding(.vertical, 9).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 8).fill(model.polling == r ? Theme.accent : Color.white.opacity(0.06)))
                            .foregroundStyle(model.polling == r ? .white : Theme.muted)
                    }
                }
                .disabled(!model.supportsPolling).opacity(model.supportsPolling ? 1 : 0.4)
            }
            Panel(title: "Sensor & Buttons") {
                Toggle("Ripple Control", isOn: $model.rippleControl).toggleStyle(.switch).tint(Theme.accent2)
                Toggle("Angle Snap", isOn: $model.angleSnap).toggleStyle(.switch).tint(Theme.accent2)
                LabeledSlider(title: "Button debounce", value: $model.light.debounce, range: 2...25)
            }
            Panel(title: "Power") {
                LabeledSlider(title: "Lights off after", value: $model.light.lightOffMinutes, range: 1...60, unit: " min")
                LabeledSlider(title: "Deep sleep after", value: $model.light.sleepMinutes, range: 1...60, unit: " min")
            }
        }
    }
}

// MARK: - Helpers
extension Color {
    init(rgb: RGB) { self.init(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255) }
    var rgb: RGB {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return RGB(UInt8(max(0, min(255, ns.redComponent * 255))),
                   UInt8(max(0, min(255, ns.greenComponent * 255))),
                   UInt8(max(0, min(255, ns.blueComponent * 255))))
    }
}
