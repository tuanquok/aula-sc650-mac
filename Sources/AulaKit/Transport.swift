import Foundation

/// Packet channel. `DryRunTransport` only records packets for testing; it never touches hardware.
public protocol Transport {
    func send(_ packet: [UInt8]) throws
}

public final class DryRunTransport: Transport {
    public private(set) var sent: [[UInt8]] = []
    public init() {}
    public func send(_ packet: [UInt8]) throws { sent.append(packet) }
}

public func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}
