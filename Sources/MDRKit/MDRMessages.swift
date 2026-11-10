/// The handful of MDR v2 messages needed to see and control which multipoint device is the audio source.
///
/// Byte layouts mirror mos9527/SonyHeadphonesClient (`libmdr/include/mdr/Generated/ProtocolV2T2.hpp`), which was
/// reverse-engineered from Sony's Sound Connect app. Every payload starts with a command byte, and peripheral
/// commands follow it with a `PeripheralInquiredType`.

public enum PeripheralInquiredType: UInt8, Codable, Sendable {
    case pairingClassic = 0x00
    case sourceSwitchControl = 0x01
    case pairingWithClassOfDevice = 0x02
}

public enum ConnectivityAction: UInt8, Sendable {
    case disconnect = 0x00
    case connect = 0x01
}

/// Table-2 `FunctionType` codes the headphones advertise in CONNECT_RET_SUPPORT_FUNCTION.
public enum T2Function {
    public static let pairingClassic: UInt8 = 0x30
    public static let sourceSwitchControl: UInt8 = 0x31
    public static let pairingWithClassOfDeviceClassic: UInt8 = 0x32
    public static let pairingWithClassOfDeviceLE: UInt8 = 0x33
}

enum Command {
    static let connectGetProtocolInfo: UInt8 = 0x00  // table 1
    static let connectRetProtocolInfo: UInt8 = 0x01  // table 1
    static let connectGetSupportFunction: UInt8 = 0x06
    static let connectRetSupportFunction: UInt8 = 0x07
    static let peripheralGetParam: UInt8 = 0x36
    static let peripheralRetParam: UInt8 = 0x37
    static let peripheralSetParam: UInt8 = 0x38
    static let peripheralNotifyParam: UInt8 = 0x39
    static let peripheralSetExtendedParam: UInt8 = 0x3C
    static let peripheralNotifyExtendedParam: UInt8 = 0x3D
}

public enum MDRRequest {
    /// Table 1. Must be the first thing sent; the reply also tells us the protocol generation.
    public static let protocolInfo: [UInt8] = [Command.connectGetProtocolInfo, 0x00]
    /// Send on table 1 or table 2; each table answers with its own function list.
    public static let supportFunctions: [UInt8] = [Command.connectGetSupportFunction, 0x00]

    public static func pairedDevices(_ type: PeripheralInquiredType) -> [UInt8] {
        [Command.peripheralGetParam, type.rawValue]
    }

    public static let autoSwitch: [UInt8] = [Command.peripheralGetParam, PeripheralInquiredType.sourceSwitchControl.rawValue]

    /// Whether the headphones may hand playback to the other device on their own when it starts playing.
    public static func setAutoSwitch(_ enabled: Bool) -> [UInt8] {
        [Command.peripheralSetParam, PeripheralInquiredType.sourceSwitchControl.rawValue, enabled ? 1 : 0]
    }

    /// Moves playback to an already connected device. `address` is the 17-byte ASCII address the headphones reported.
    public static func switchSource(to address: [UInt8]) -> [UInt8] {
        [Command.peripheralSetExtendedParam, PeripheralInquiredType.sourceSwitchControl.rawValue] + address
    }

    public static func connectivity(_ action: ConnectivityAction, _ type: PeripheralInquiredType, address: [UInt8]) -> [UInt8] {
        [Command.peripheralSetExtendedParam, type.rawValue, action.rawValue] + address
    }
}

public struct PairedDevice: Equatable, Codable, Sendable, Identifiable {
    /// 17 ASCII bytes, e.g. "AA:BB:CC:DD:EE:FF". Echoed back verbatim in commands.
    public var addressBytes: [UInt8]
    public var name: String
    /// Non-zero while connected; equals the list's playback slot for the device that currently has the audio.
    public var connectionSlot: UInt8
    public var classOfDevice: UInt32?
    public var isPlaying: Bool

    public init(addressBytes: [UInt8], name: String, connectionSlot: UInt8, classOfDevice: UInt32?, isPlaying: Bool) {
        self.addressBytes = addressBytes
        self.name = name
        self.connectionSlot = connectionSlot
        self.classOfDevice = classOfDevice
        self.isPlaying = isPlaying
    }

    public var id: String { address }
    public var address: String { String(decoding: addressBytes, as: UTF8.self) }
    public var isConnected: Bool { connectionSlot != 0 }
    /// Hex digits only, uppercased, for comparing against addresses formatted differently (e.g. "aa-bb-…").
    public var normalizedAddress: String { normalizeAddress(address) }
}

public enum DeviceKind: String, Codable, Sendable {
    case laptop, desktop, tablet, phone, speaker, tv, watch, unknown
}

extension PairedDevice {
    /// Derived from the Bluetooth Class of Device, when the headphones report it.
    public var kind: DeviceKind {
        guard let cod = classOfDevice else { return .unknown }
        let major = (cod >> 8) & 0x1F
        let minor = (cod >> 2) & 0x3F
        switch major {
        case 0x01:
            switch minor {
            case 0x03: return .laptop
            case 0x05, 0x06: return .tablet
            default: return .desktop
            }
        case 0x02: return .phone
        case 0x04: return minor == 0x0F ? .tv : .speaker
        case 0x07: return .watch
        default: return .unknown
        }
    }
}

public func normalizeAddress(_ address: String) -> String {
    address.filter(\.isHexDigit).uppercased()
}

public enum SourceSwitchResult: UInt8, Sendable {
    case success = 0x00
    case failed = 0x01
    case inCall = 0x02
    case audioNotConnected = 0x03
    case voiceAssistantActive = 0x04

    public var message: String {
        switch self {
        case .success: return "Switched"
        case .failed: return "The headphones refused to switch"
        case .inCall: return "Can't switch during a call"
        case .audioNotConnected: return "That device has no audio connection to the headphones"
        case .voiceAssistantActive: return "Can't switch while the voice assistant is active"
        }
    }
}

public struct ProtocolInfo: Equatable, Sendable {
    public var version: UInt32
    public var hasTable1: Bool
    public var hasTable2: Bool
}

public enum T2Message: Equatable, Sendable {
    case supportFunctions(Set<UInt8>)
    case pairedDevices([PairedDevice], source: PeripheralInquiredType)
    case autoSwitch(enabled: Bool)
    case sourceSwitchResult(code: UInt8, address: String)
    case connectivityResult(action: UInt8, result: UInt8, address: String)
    case micMute(MicMuteSettings)
    case other(command: UInt8)
}

public enum MDRParser {
    public static func protocolInfo(_ payload: [UInt8]) -> ProtocolInfo? {
        var reader = ByteReader(payload)
        guard reader.u8() == Command.connectRetProtocolInfo, reader.u8() != nil,
              let version = reader.u32(), let t1 = reader.u8(), let t2 = reader.u8() else { return nil }
        // EnableDisable: 0x00 = enabled.
        return ProtocolInfo(version: version, hasTable1: t1 == 0x00, hasTable2: t2 == 0x00)
    }

    /// Parses a table-1 CONNECT_RET_SUPPORT_FUNCTION; table 2 goes through `parseT2`.
    public static func supportFunctions(_ payload: [UInt8]) -> Set<UInt8>? {
        var reader = ByteReader(payload)
        guard reader.u8() == Command.connectRetSupportFunction else { return nil }
        return readSupportFunctions(&reader)
    }

    public static func parseT2(_ payload: [UInt8]) -> T2Message? {
        var reader = ByteReader(payload)
        guard let command = reader.u8() else { return nil }
        switch command {
        case Command.connectRetSupportFunction:
            return readSupportFunctions(&reader).map(T2Message.supportFunctions)

        case Command.peripheralRetParam, Command.peripheralNotifyParam:
            guard let rawType = reader.u8(), let type = PeripheralInquiredType(rawValue: rawType) else {
                return .other(command: command)
            }
            switch type {
            case .pairingClassic, .pairingWithClassOfDevice:
                return readDeviceList(&reader, withClassOfDevice: type == .pairingWithClassOfDevice)
                    .map { .pairedDevices($0, source: type) }
            case .sourceSwitchControl:
                return reader.u8().map { .autoSwitch(enabled: $0 != 0) }
            }

        case Command.peripheralNotifyExtendedParam:
            guard let rawType = reader.u8(), let type = PeripheralInquiredType(rawValue: rawType) else {
                return .other(command: command)
            }
            switch type {
            case .sourceSwitchControl:
                guard let code = reader.u8(), let address = reader.bytes(17) else { return nil }
                return .sourceSwitchResult(code: code, address: String(decoding: address, as: UTF8.self))
            case .pairingClassic, .pairingWithClassOfDevice:
                guard let action = reader.u8(), let result = reader.u8(), let address = reader.bytes(17) else { return nil }
                return .connectivityResult(action: action, result: result, address: String(decoding: address, as: UTF8.self))
            }

        case SettingsCommand.systemRetParam, SettingsCommand.systemNotifyParam:
            guard let type = reader.u8() else { return nil }
            guard type == SystemInquiredType.micMuteByHeadphones else { return .other(command: command) }
            return readMicMute(&reader).map(T2Message.micMute)

        default:
            return .other(command: command)
        }
    }

    static func readSupportFunctions(_ reader: inout ByteReader) -> Set<UInt8>? {
        guard reader.u8() != nil, let count = reader.u8() else { return nil }
        var functions = Set<UInt8>()
        for _ in 0..<count {
            guard let function = reader.u8(), reader.u8() != nil /* priority */ else { return nil }
            functions.insert(function)
        }
        return functions
    }

    private static func readDeviceList(_ reader: inout ByteReader, withClassOfDevice: Bool) -> [PairedDevice]? {
        guard let count = reader.u8() else { return nil }
        var devices: [PairedDevice] = []
        for _ in 0..<count {
            guard let address = reader.bytes(17), let slot = reader.u8() else { return nil }
            var classOfDevice: UInt32?
            if withClassOfDevice {
                guard let cod = reader.u24() else { return nil }
                classOfDevice = cod
            }
            guard let nameLength = reader.u8(), let name = reader.bytes(Int(nameLength)) else { return nil }
            devices.append(PairedDevice(addressBytes: address, name: String(decoding: name, as: UTF8.self),
                                        connectionSlot: slot, classOfDevice: classOfDevice, isPlaying: false))
        }
        let playbackSlot = reader.u8() ?? 0
        for index in devices.indices where devices[index].isConnected {
            devices[index].isPlaying = devices[index].connectionSlot == playbackSlot
        }
        return devices
    }
}

struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func u8() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func bytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, offset + count <= bytes.count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func u24() -> UInt32? {
        bytes(3).map { UInt32($0[0]) << 16 | UInt32($0[1]) << 8 | UInt32($0[2]) }
    }

    mutating func u32() -> UInt32? {
        bytes(4).map { UInt32($0[0]) << 24 | UInt32($0[1]) << 16 | UInt32($0[2]) << 8 | UInt32($0[3]) }
    }
}
