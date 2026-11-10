import Foundation

/// A live connection to the mouse (2.4G receiver, wired USB or Bluetooth LE).
/// The app only talks to this protocol, so every connection type shares the same code path.
public protocol MouseLink: AnyObject {
    var connectionTitle: String { get }
    /// The original app never sends the polling-rate packet (0x06) over Bluetooth.
    var supportsPollingRate: Bool { get }
    var received: [[UInt8]] { get }
    var onInput: (([UInt8]) -> Void)? { get set }
    func listen(seconds: Double)
    func send(_ packet: [UInt8]) throws
    func sendAwaitingAck(_ packet: [UInt8], attempts: Int, wait: Double) throws -> Bool
    func sendMacroPacket(_ logical: [UInt8], attempts: Int) throws -> Bool
}

extension MouseLink {
    /// Send, then wait for the mouse's acknowledge event (kind 0x50) for the same report ID.
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
}

extension MouseLink {
    @discardableResult
    public func sendMacroPacket(_ logical: [UInt8]) throws -> Bool { try sendMacroPacket(logical, attempts: 3) }
}

extension HIDTransport: MouseLink {
    public var connectionTitle: String { connection.title }
    public var supportsPollingRate: Bool { true }
}
