/// Framing for Sony's "MDR" headphone control protocol, spoken over an RFCOMM channel.
///
/// On the wire every packet looks like:
///
///     0x3E | escape( dataType, seq, len:UInt32BE, payload…, checksum ) | 0x3C
///
/// where `checksum` is the 8-bit sum of everything before it and the bytes 0x3C/0x3D/0x3E are escaped as
/// 0x3D followed by the byte with bit 4 cleared. Reference: mos9527/SonyHeadphonesClient `libmdr/src/Command.cpp`.

public struct MDRPacket: Equatable, Sendable {
    public var dataType: UInt8
    public var sequence: UInt8
    public var payload: [UInt8]

    public init(dataType: UInt8, sequence: UInt8, payload: [UInt8] = []) {
        self.dataType = dataType
        self.sequence = sequence
        self.payload = payload
    }
}

public enum MDRDataType {
    public static let ack: UInt8 = 0x01
    /// Commands from protocol table 1 (`DATA_MDR`).
    public static let table1: UInt8 = 0x0C
    /// Commands from protocol table 2 (`DATA_MDR_NO2`), which is where multipoint/peripheral control lives.
    public static let table2: UInt8 = 0x0E
}

public enum MDRCodec {
    static let startMarker: UInt8 = 0x3E
    static let endMarker: UInt8 = 0x3C
    static let escapeMarker: UInt8 = 0x3D

    public static func encode(_ packet: MDRPacket) -> [UInt8] {
        let length = UInt32(packet.payload.count)
        var body: [UInt8] = [
            packet.dataType, packet.sequence,
            UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
        ]
        body += packet.payload
        body.append(checksum(body))

        var out: [UInt8] = [startMarker]
        out.reserveCapacity(body.count + 8)
        for byte in body {
            if (0x3C...0x3E).contains(byte) {
                out.append(escapeMarker)
                out.append(byte & 0xEF)
            } else {
                out.append(byte)
            }
        }
        out.append(endMarker)
        return out
    }

    /// Decodes the escaped bytes found between a start and an end marker (markers excluded).
    public static func decode<C: Collection>(escapedBody: C) -> MDRPacket? where C.Element == UInt8 {
        var raw: [UInt8] = []
        raw.reserveCapacity(escapedBody.count)
        var iterator = escapedBody.makeIterator()
        while let byte = iterator.next() {
            if byte == escapeMarker {
                guard let next = iterator.next(), (0x2C...0x2E).contains(next) else { return nil }
                raw.append(next | 0x10)
            } else {
                raw.append(byte)
            }
        }
        guard raw.count >= 7 else { return nil }
        let length = Int(raw[2]) << 24 | Int(raw[3]) << 16 | Int(raw[4]) << 8 | Int(raw[5])
        guard raw.count == 7 + length, checksum(raw.dropLast()) == raw[raw.count - 1] else { return nil }
        return MDRPacket(dataType: raw[0], sequence: raw[1], payload: Array(raw[6..<(6 + length)]))
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        bytes.reduce(0, &+)
    }
}

/// Reassembles packets from an RFCOMM byte stream, which may split or coalesce frames arbitrarily.
public struct MDRStreamDecoder {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed<S: Sequence>(_ bytes: S) -> [MDRPacket] where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var packets: [MDRPacket] = []
        while let end = buffer.firstIndex(of: MDRCodec.endMarker) {
            // Markers never appear escaped, so the last start marker before `end` begins this frame;
            // anything earlier is a truncated frame or line noise.
            if let start = buffer[..<end].lastIndex(of: MDRCodec.startMarker),
               let packet = MDRCodec.decode(escapedBody: buffer[(start + 1)..<end]) {
                packets.append(packet)
            }
            buffer.removeFirst(end + 1)
        }
        if buffer.count > 16_384 { buffer.removeAll() } // never let garbage grow unbounded
        return packets
    }
}
