import Foundation
import CoreBluetooth

public enum BLEError: Error, CustomStringConvertible {
    case unauthorized, waitingForPermission, poweredOff, notFound, notReady
    case missingCharacteristics(String)
    case timeout(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .unauthorized:
            return "Bluetooth access was denied. Allow AULA SC650 in System Settings > Privacy & Security > Bluetooth."
        case .waitingForPermission:
            return "Waiting for Bluetooth permission. Click Allow in the macOS dialog, then press the refresh button."
        case .poweredOff: return "Bluetooth is turned off."
        case .notFound: return "AULA-SC650 was not found over Bluetooth. Pair it first and switch the mouse to Bluetooth mode."
        case .notReady: return "The Bluetooth link is not ready."
        case .missingCharacteristics(let found):
            return "The mouse does not expose the control characteristics (FEE3/FEE4). Found: \(found)"
        case .timeout(let what): return "Bluetooth timed out while \(what)."
        case .writeFailed(let why): return "Bluetooth write failed: \(why)"
        }
    }
}

/// Bluetooth LE link to the SC650.
///
/// The Windows app (Mouse.exe, functions 0x405880 / 0x406070 / 0x415D70) talks to the mouse through a vendor GATT
/// characteristic instead of HID feature reports:
///  - commands are written as-is (byte 0 = report ID) to the characteristic with 16-bit UUID 0xFEE3;
///  - events arrive as notifications on 0xFEE4 and are 4 bytes `[8E, kind, b3, b4]`
///    (the 2.4G receiver sends the same event with a leading 0x03, which we prepend so one parser serves both).
public final class BLETransport: NSObject, MouseLink {
    public static let writeUUID = CBUUID(string: "FEE3")
    public static let notifyUUID = CBUUID(string: "FEE4")
    private static let probeServices = ["FEE0", "FEE1", "FEE2", "FEE3", "FEE4", "180F", "1812", "180A"].map { CBUUID(string: $0) }
    private static let savedIDKey = "aula.sc650.ble.peripheral"

    public var connectionTitle: String { "Bluetooth" }
    public var supportsPollingRate: Bool { false }

    /// CoreBluetooth delivers its callbacks on this private queue, never on the main queue: the app applies settings
    /// synchronously on the main thread, which would otherwise starve the callbacks and every write would time out.
    private let queue = DispatchQueue(label: "aula.sc650.ble")
    private let lock = NSLock()
    private var _received: [[UInt8]] = []
    private var _writeDone = false
    private var _writeError: Error?
    private var _writeChar: CBCharacteristic?
    public var received: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return _received }
    public var onInput: (([UInt8]) -> Void)?
    public var onDisconnect: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var notifyChar: CBCharacteristic?
    private var pendingServices = 0
    private var completion: ((Result<BLETransport, Error>) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    private var stage = "starting Bluetooth"
    private var scan = true

    private override init() { super.init() }

    /// Starts connecting. The returned object must be retained by the caller until `completion` fires and afterwards.
    @discardableResult
    public static func open(timeout: TimeInterval = 12, scan: Bool = true,
                            completion: @escaping (Result<BLETransport, Error>) -> Void) -> BLETransport {
        let t = BLETransport()
        t.scan = scan
        t.completion = completion
        t.central = CBCentralManager(delegate: t, queue: t.queue)
        let work = DispatchWorkItem { [weak t] in
            guard let t else { return }
            switch CBManager.authorization {
            case .notDetermined: t.finish(.failure(BLEError.waitingForPermission))
            case .denied, .restricted: t.finish(.failure(BLEError.unauthorized))
            default: t.finish(.failure(t.peripheral == nil ? BLEError.notFound : BLEError.timeout(t.stage)))
            }
        }
        t.timeoutWork = work
        t.queue.asyncAfter(deadline: .now() + timeout, execute: work)
        return t
    }

    public func close() {
        timeoutWork?.cancel()
        queue.async { [self] in
            completion = nil
            if let p = peripheral, p.state != .disconnected { central.cancelPeripheralConnection(p) }
            central.stopScan()
        }
    }

    private func finish(_ result: Result<BLETransport, Error>) {
        guard let done = completion else { return }
        completion = nil
        timeoutWork?.cancel()
        central.stopScan()
        DispatchQueue.main.async { done(result) }
    }

    private static func isAula(_ p: CBPeripheral) -> Bool {
        let n = (p.name ?? "").uppercased()
        return n.contains("AULA") || n.contains("SC650")
    }

    private func attach(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central.stopScan()
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedIDKey)
        if p.state == .connected {
            stage = "discovering services"
            p.discoverServices(nil)
        } else {
            stage = "connecting"
            central.connect(p)
        }
    }

    private func search() {
        stage = "looking for the mouse"
        if let s = UserDefaults.standard.string(forKey: Self.savedIDKey), let id = UUID(uuidString: s),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first, Self.isAula(p) { attach(p); return }
        if let p = central.retrieveConnectedPeripherals(withServices: Self.probeServices).first(where: Self.isAula) {
            attach(p); return
        }
        if !scan { finish(.failure(BLEError.notFound)); return }
        central.scanForPeripherals(withServices: nil)
    }

    public func listen(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    public func send(_ packet: [UInt8]) throws {
        lock.lock(); let ch = _writeChar; lock.unlock()
        guard let p = peripheral, let ch, p.state == .connected else { throw BLEError.notReady }
        let withResponse = ch.properties.contains(.write)
        if !withResponse {
            let limit = p.maximumWriteValueLength(for: .withoutResponse)
            if packet.count > limit { throw BLEError.writeFailed("packet is \(packet.count) bytes but the link allows \(limit)") }
        }
        lock.lock(); _writeDone = false; _writeError = nil; lock.unlock()
        queue.async { p.writeValue(Data(packet), for: ch, type: withResponse ? .withResponse : .withoutResponse) }
        if withResponse {
            let deadline = Date().addingTimeInterval(5)
            var done = false, err: Error?
            while Date() < deadline {
                lock.lock(); done = _writeDone; err = _writeError; lock.unlock()
                if done { break }
                listen(seconds: 0.01)
            }
            if let err { throw BLEError.writeFailed(err.localizedDescription) }
            if !done { throw BLEError.timeout("writing a packet") }
        } else {
            listen(seconds: 0.05)
        }
    }

    /// Macro packets are written whole (the Windows app does not split them over Bluetooth).
    @discardableResult
    public func sendMacroPacket(_ logical: [UInt8], attempts: Int = 3) throws -> Bool {
        for _ in 0..<attempts {
            let mark = received.count
            try send(logical)
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
}

extension BLETransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: search()
        case .unauthorized: finish(.failure(BLEError.unauthorized))
        case .poweredOff: finish(.failure(BLEError.poweredOff))
        default: break
        }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if Self.isAula(p) { attach(p) }
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        stage = "discovering services"
        p.discoverServices(nil)
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        finish(.failure(BLEError.writeFailed(error?.localizedDescription ?? "could not connect")))
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        lock.lock(); _writeChar = nil; lock.unlock()
        notifyChar = nil
        onDisconnect?()
    }
}

extension BLETransport: CBPeripheralDelegate {
    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { finish(.failure(BLEError.writeFailed(error.localizedDescription))); return }
        let services = p.services ?? []
        pendingServices = services.count
        stage = "discovering characteristics"
        if services.isEmpty { reportMissing(p) }
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == Self.writeUUID, ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
                lock.lock(); _writeChar = ch; lock.unlock()
            } else if ch.uuid == Self.notifyUUID, ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                notifyChar = ch
            }
        }
        pendingServices -= 1
        guard pendingServices <= 0 else { return }
        lock.lock(); let haveWrite = _writeChar != nil; lock.unlock()
        guard haveWrite, let n = notifyChar else { reportMissing(p); return }
        stage = "subscribing to notifications"
        p.setNotifyValue(true, for: n)
    }

    private func reportMissing(_ p: CBPeripheral) {
        let found = (p.services ?? []).map { s in
            "\(s.uuid.uuidString)[" + (s.characteristics ?? []).map { $0.uuid.uuidString }.joined(separator: ",") + "]"
        }.joined(separator: " ")
        finish(.failure(BLEError.missingCharacteristics(found.isEmpty ? "no services" : found)))
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let error { finish(.failure(BLEError.writeFailed(error.localizedDescription))); return }
        if ch.uuid == Self.notifyUUID, ch.isNotifying { finish(.success(self)) }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard error == nil, ch.uuid == Self.notifyUUID, let data = ch.value else { return }
        let bytes = [UInt8](data)
        let report = DeviceEvent.normalizeBLE(bytes)
        lock.lock(); _received.append(report); lock.unlock()
        onInput?(report)
    }

    public func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        lock.lock(); _writeError = error; _writeDone = true; lock.unlock()
    }
}
