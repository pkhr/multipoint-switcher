import Foundation
import MDRKit

/// A stand-in for real headphones that ACKs every packet and answers the way a 1000X The ColleXion does.
/// The tests run against it, and the apps use it for a demo mode where there's no Bluetooth (the iOS Simulator).
@MainActor
public final class SimulatedHeadphones: HeadphoneTransport {
    /// What the simulated headphones remember between connections, in wire format.
    public final class Memory {
        public var noise: [UInt8] = [0x01, 0x01, 0x00, 0x00, 0x14, 0x00, 0x00] // settled, on, NC, normal, level 20, manual, standard
        public var sidetoneOff: UInt8 = 0x01
        public var speakToChat: [UInt8] = [0x00, 0x01]
        public var speakToChatDetail: [UInt8] = [0x00, 0x00]
        public var micMute: [UInt8] = [0x00, 0x01]
        public var autoSwitch: UInt8 = 0x01
        /// The equalizer: the selected preset, and the ten bands of each preset (0…12, 6 is flat).
        public var equalizerPreset: UInt8 = 0x00
        public var equalizerBands: [UInt8: [UInt8]] = [
            0x00: [6, 6, 6, 6, 6, 6, 6, 6, 6, 6], 0x10: [5, 5, 6, 6, 7, 8, 9, 10, 11, 11], 0x11: [10, 9, 7, 6, 6, 7, 8, 9, 10, 10],
            0x12: [7, 7, 6, 6, 5, 5, 4, 4, 3, 3], 0x13: [5, 5, 5, 6, 6, 6, 5, 5, 4, 4], 0x14: [5, 5, 6, 7, 9, 10, 9, 8, 7, 6],
            0x16: [12, 11, 9, 7, 6, 6, 6, 6, 6, 6], 0xA0: [6, 6, 6, 6, 6, 6, 6, 6, 6, 6], 0xA1: [8, 7, 6, 6, 6, 6, 6, 7, 8, 8],
        ]
        public var playbackSlot: UInt8 = 1
        public var tabletSlot: UInt8 = 0
        /// A SourceSwitchResult code to answer switch requests with, instead of switching.
        public var refuseSwitchWith: UInt8?

        public init() {}
    }

    public weak var delegate: HeadphoneTransportDelegate?
    public let memory: Memory
    /// Makes `open()` fail with this message.
    public var failOpen: String?
    public private(set) var isOpen = false
    public private(set) var closeCount = 0
    /// Every data packet received, as (table, payload).
    public private(set) var received: [(table: UInt8, payload: [UInt8])] = []

    public static let mac = Array("AA:BB:CC:DD:EE:01".utf8)
    public static let phone = Array("AA:BB:CC:DD:EE:02".utf8)
    public static let tablet = Array("AA:BB:CC:DD:EE:03".utf8)

    public init(memory: Memory = Memory()) {
        self.memory = memory
    }

    private var decoder = MDRStreamDecoder()
    private var sequence: UInt8 = 0

    public func received(_ command: UInt8, table: UInt8) -> [[UInt8]] {
        received.filter { $0.table == table && $0.payload.first == command }.map(\.payload)
    }

    public func open() {
        Task { @MainActor in
            if let failOpen {
                self.delegate?.transport(self, didCloseWithError: failOpen)
            } else {
                self.isOpen = true
                self.delegate?.transportDidOpen(self)
            }
        }
    }

    public func close() {
        if isOpen { closeCount += 1 }
        isOpen = false
    }

    public func write(_ bytes: [UInt8]) {
        guard isOpen else { return }
        for packet in decoder.feed(bytes) where packet.dataType != MDRDataType.ack {
            received.append((packet.dataType, packet.payload))
            var out = [MDRPacket(dataType: MDRDataType.ack, sequence: packet.sequence == 0 ? 1 : 0)]
            for payload in respond(packet.dataType, packet.payload) {
                out.append(MDRPacket(dataType: packet.dataType, sequence: sequence, payload: payload))
                sequence = sequence == 0 ? 1 : 0
            }
            let packets = out
            Task { @MainActor in
                for packet in packets where self.isOpen {
                    self.delegate?.transport(self, didReceive: MDRCodec.encode(packet))
                }
            }
        }
    }

    private func equalizerReply(_ command: UInt8) -> [UInt8] {
        let bands = memory.equalizerBands[memory.equalizerPreset] ?? []
        return [command, 0x00, memory.equalizerPreset, UInt8(bands.count)] + bands
    }

    private func respond(_ table: UInt8, _ p: [UInt8]) -> [[UInt8]] {
        if table == MDRDataType.table1 {
            switch (p[0], p.count > 1 ? p[1] : 0) {
            case (0x00, _): return [[0x01, 0x00, 0x03, 0x00, 0x10, 0x02, 0x00, 0x00]]
            case (0x06, _): return [[0x07, 0x00, 0x06, 0x6D, 0x0B, 0xFC, 0x0D, 0xD1, 0x3F, 0xD3, 0x2D, 0x69, 0x2E, 0x57, 0x14]]
            case (0x50, 0x04):
                // Ten bands of thirteen steps. Names are left empty or sent as identifiers, as real firmware may.
                var reply: [UInt8] = [0x51, 0x04, 10, 13, UInt8(memory.equalizerBands.count)]
                for id in memory.equalizerBands.keys.sorted() {
                    let name = id == 0x16 ? Array("EQ_BASS_BOOST".utf8) : []
                    reply += [id, UInt8(name.count)] + name
                }
                return [reply]
            case (0x52, 0x00): return [[0x53, 0x00, 0x00, 0x00]]
            case (0x56, 0x00): return [equalizerReply(0x57)]
            case (0x58, 0x00):
                guard p.count >= 4, memory.equalizerBands[p[2]] != nil else { return [] }
                memory.equalizerPreset = p[2]
                if p[3] == 10, p.count == 14 { memory.equalizerBands[p[2]] = Array(p[4...]) }
                return [equalizerReply(0x59)]
            case (0xD0, 0xD1): return [[0xD1, 0xD1, 0x00, 0x01, 16] + Array("SIDETONE_SETTING".utf8) + [0]]
            case (0xD0, 0xD3): return [[0xD1, 0xD3, 0x00, 0x01, 19] + Array("TOUCH_PANEL_SETTING".utf8) + [0]]
            case (0xD6, 0xD1): return [[0xD7, 0xD1, 0x00, memory.sidetoneOff]]
            case (0xD8, 0xD1):
                memory.sidetoneOff = p[3]
                return [[0xD9, 0xD1, 0x00, memory.sidetoneOff]]
            case (0x66, 0x19): return [[0x67, 0x19] + memory.noise]
            case (0x68, 0x19):
                memory.noise = Array(p[2...])
                return [[0x69, 0x19] + memory.noise]
            case (0xF6, 0x0C): return [[0xF7, 0x0C] + memory.speakToChat]
            case (0xF8, 0x0C):
                memory.speakToChat = Array(p[2...])
                return [[0xF9, 0x0C] + memory.speakToChat]
            case (0xFA, 0x0C): return [[0xFB, 0x0C] + memory.speakToChatDetail]
            case (0xFC, 0x0C):
                memory.speakToChatDetail = Array(p[2...])
                return [[0xFD, 0x0C] + memory.speakToChatDetail]
            default: return []
            }
        }
        switch (p[0], p.count > 1 ? p[1] : 0) {
        case (0x06, _): return [[0x07, 0x00, 0x04, 0x30, 0xFF, 0x31, 0xFF, 0x32, 0xFF, 0xF9, 0xFF]]
        case (0x36, 0x02):
            func entry(_ address: [UInt8], _ slot: UInt8, _ cod: [UInt8], _ name: String) -> [UInt8] {
                address + [slot] + cod + [UInt8(name.utf8.count)] + Array(name.utf8)
            }
            return [[0x37, 0x02, 0x03]
                + entry(Self.mac, 1, [0x38, 0x01, 0x0C], "MacBook")
                + entry(Self.phone, 2, [0x7A, 0x02, 0x0C], "iPhone")
                + entry(Self.tablet, memory.tabletSlot, [0x1A, 0x01, 0x18], "iPad")
                + [memory.playbackSlot]]
        case (0x36, 0x01): return [[0x37, 0x01, memory.autoSwitch]]
        case (0x38, 0x01):
            memory.autoSwitch = p[2]
            return []
        case (0x3C, 0x01):
            let address = Array(p[2...])
            if let refusal = memory.refuseSwitchWith { return [[0x3D, 0x01, refusal] + address] }
            memory.playbackSlot = address == Self.mac ? 1 : address == Self.phone ? 2 : 3
            return [[0x3D, 0x01, 0x00] + address]
        case (0x3C, 0x02):
            let address = Array(p[3...])
            if address == Self.tablet { memory.tabletSlot = p[2] == 0x01 ? 3 : 0 }
            return [[0x3D, 0x02, p[2], 0x02] + address]
        case (0xF6, 0x0B): return [[0xF7, 0x0B] + memory.micMute]
        case (0xF8, 0x0B):
            memory.micMute = Array(p[2...])
            return [[0xF9, 0x0B] + memory.micMute]
        default: return []
        }
    }
}
