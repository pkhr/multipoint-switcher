/// Microphone-related headphone settings: sidetone, Speak-to-Chat and muting the mic from the headphones.
///
/// Layouts mirror mos9527/SonyHeadphonesClient (`ProtocolV2T1.hpp`, `ProtocolV2T2.hpp`). In these messages the
/// protocol's on/off byte is inverted: 0x00 means on, 0x01 off.

/// Table-1 `FunctionType` codes the headphones advertise in CONNECT_RET_SUPPORT_FUNCTION.
public enum T1Function {
    /// SMART_TALKING_MODE_TYPE2: Speak-to-Chat.
    public static let speakToChat: UInt8 = 0xFC
    /// GENERAL_SETTING_1…4: model-specific switches that the headphones name themselves (e.g. "SIDETONE_SETTING").
    public static let generalSettings: [UInt8] = [0xD1, 0xD2, 0xD3, 0xD4]
}

extension T2Function {
    /// MIC_ON_OFF_BY_HEADPHONE_OPERATION: mute the mic with a headphone control during calls.
    public static let micMuteByHeadphones: UInt8 = 0xF9
}

enum SettingsCommand {
    static let generalGetCapability: UInt8 = 0xD0
    static let generalRetCapability: UInt8 = 0xD1
    static let generalGetParam: UInt8 = 0xD6
    static let generalRetParam: UInt8 = 0xD7
    static let generalSetParam: UInt8 = 0xD8
    static let generalNotifyParam: UInt8 = 0xD9
    // The system commands use the same codes on both tables.
    static let systemGetParam: UInt8 = 0xF6
    static let systemRetParam: UInt8 = 0xF7
    static let systemSetParam: UInt8 = 0xF8
    static let systemNotifyParam: UInt8 = 0xF9
    static let systemGetExtParam: UInt8 = 0xFA
    static let systemRetExtParam: UInt8 = 0xFB
    static let systemSetExtParam: UInt8 = 0xFC
    static let systemNotifyExtParam: UInt8 = 0xFD
}

enum SystemInquiredType {
    static let speakToChat: UInt8 = 0x0C          // table 1, SMART_TALKING_MODE_TYPE2
    static let micMuteByHeadphones: UInt8 = 0x0B  // table 2, MIC_ON_OFF_BY_HEADPHONE_OPERATION
}

private let booleanSettingType: UInt8 = 0x00
private let englishLanguage: UInt8 = 0x01

private func onOffByte(_ on: Bool) -> UInt8 { on ? 0x00 : 0x01 }

private func isOn(_ byte: UInt8?) -> Bool? {
    switch byte {
    case 0x00?: return true
    case 0x01?: return false
    default: return nil
    }
}

public enum SpeakToChatSensitivity: UInt8, CaseIterable, Codable, Sendable {
    case auto = 0x00, high = 0x01, low = 0x02
}

/// How long after you stop talking Speak-to-Chat ends and the music resumes.
public enum SpeakToChatTimeout: UInt8, CaseIterable, Codable, Sendable {
    case short = 0x00, standard = 0x01, long = 0x02, never = 0x03
}

public struct SpeakToChatDetail: Equatable, Codable, Sendable {
    public var sensitivity: SpeakToChatSensitivity
    public var timeout: SpeakToChatTimeout

    public init(sensitivity: SpeakToChatSensitivity, timeout: SpeakToChatTimeout) {
        self.sensitivity = sensitivity
        self.timeout = timeout
    }
}

public struct MicMuteSettings: Equatable, Codable, Sendable {
    /// A headphone control mutes and unmutes the mic during calls.
    public var buttonMutes: Bool
    /// The headphones play a sound when the mic is muted.
    public var playsSound: Bool

    public init(buttonMutes: Bool, playsSound: Bool) {
        self.buttonMutes = buttonMutes
        self.playsSound = playsSound
    }
}

/// A general setting as the headphones describe it.
public struct GeneralSettingInfo: Equatable, Codable, Sendable {
    public var index: UInt8
    public var isBoolean: Bool
    /// An identifier such as "SIDETONE_SETTING", or display text on models that send raw names.
    public var subject: String
    public var summary: String

    public init(index: UInt8, isBoolean: Bool, subject: String, summary: String) {
        self.index = index
        self.isBoolean = isBoolean
        self.subject = subject
        self.summary = summary
    }

    /// Plays your own voice back in the headphones during calls.
    public var isSidetone: Bool { isBoolean && subject.uppercased().contains("SIDETONE") }
}

extension MDRRequest {
    // Table 1
    public static func generalSettingInfo(_ index: UInt8) -> [UInt8] {
        [SettingsCommand.generalGetCapability, index, englishLanguage]
    }

    public static func generalSetting(_ index: UInt8) -> [UInt8] { [SettingsCommand.generalGetParam, index] }

    public static func setGeneralSetting(_ index: UInt8, on: Bool) -> [UInt8] {
        [SettingsCommand.generalSetParam, index, booleanSettingType, onOffByte(on)]
    }

    public static let speakToChat: [UInt8] = [SettingsCommand.systemGetParam, SystemInquiredType.speakToChat]

    public static func setSpeakToChat(_ on: Bool) -> [UInt8] {
        // The second value is Sony's "preview mode", which the official app always sends as off.
        [SettingsCommand.systemSetParam, SystemInquiredType.speakToChat, onOffByte(on), onOffByte(false)]
    }

    public static let speakToChatDetail: [UInt8] = [SettingsCommand.systemGetExtParam, SystemInquiredType.speakToChat]

    public static func setSpeakToChatDetail(_ detail: SpeakToChatDetail) -> [UInt8] {
        [SettingsCommand.systemSetExtParam, SystemInquiredType.speakToChat, detail.sensitivity.rawValue, detail.timeout.rawValue]
    }

    // Table 2
    public static let micMute: [UInt8] = [SettingsCommand.systemGetParam, SystemInquiredType.micMuteByHeadphones]

    public static func setMicMute(_ settings: MicMuteSettings) -> [UInt8] {
        [SettingsCommand.systemSetParam, SystemInquiredType.micMuteByHeadphones,
         onOffByte(settings.buttonMutes), onOffByte(settings.playsSound)]
    }
}

public enum T1Message: Equatable, Sendable {
    case supportFunctions(Set<UInt8>)
    case generalSettingInfo(GeneralSettingInfo)
    case generalSetting(index: UInt8, on: Bool)
    case speakToChat(enabled: Bool)
    case speakToChatDetail(SpeakToChatDetail)
    /// `adjusting` is true while the level is still being changed (a slider being dragged in another app).
    case noiseControl(NoiseControl, adjusting: Bool)
    case equalizerInfo(EqualizerInfo)
    case equalizer(Equalizer)
    /// Whether the equalizer can be used right now; it can't during a call, for one.
    case equalizerAvailable(Bool)
    case other(command: UInt8)
}

extension MDRParser {
    /// Parses the table-1 messages this app uses (protocol info goes through `protocolInfo`).
    public static func parseT1(_ payload: [UInt8]) -> T1Message? {
        var reader = ByteReader(payload)
        guard let command = reader.u8() else { return nil }
        switch command {
        case Command.connectRetSupportFunction:
            return readSupportFunctions(&reader).map(T1Message.supportFunctions)

        case SettingsCommand.generalRetCapability:
            guard let index = reader.u8(), let type = reader.u8(), reader.u8() != nil /* string format */,
                  let subject = reader.prefixedString() else { return nil }
            return .generalSettingInfo(GeneralSettingInfo(index: index, isBoolean: type == booleanSettingType,
                                                          subject: subject, summary: reader.prefixedString() ?? ""))

        case SettingsCommand.generalRetParam, SettingsCommand.generalNotifyParam:
            guard let index = reader.u8(), let type = reader.u8() else { return nil }
            guard type == booleanSettingType else { return .other(command: command) }
            return isOn(reader.u8()).map { .generalSetting(index: index, on: $0) }

        case SettingsCommand.systemRetParam, SettingsCommand.systemNotifyParam:
            guard let type = reader.u8() else { return nil }
            guard type == SystemInquiredType.speakToChat else { return .other(command: command) }
            return isOn(reader.u8()).map { .speakToChat(enabled: $0) }

        case SettingsCommand.systemRetExtParam, SettingsCommand.systemNotifyExtParam:
            guard let type = reader.u8() else { return nil }
            guard type == SystemInquiredType.speakToChat else { return .other(command: command) }
            guard let sensitivity = reader.u8().flatMap(SpeakToChatSensitivity.init(rawValue:)),
                  let timeout = reader.u8().flatMap(SpeakToChatTimeout.init(rawValue:)) else { return nil }
            return .speakToChatDetail(SpeakToChatDetail(sensitivity: sensitivity, timeout: timeout))

        case NoiseCommand.retParam, NoiseCommand.notifyParam:
            guard let (value, adjusting) = readNoiseControl(&reader) else { return .other(command: command) }
            return .noiseControl(value, adjusting: adjusting)

        case EqualizerCommand.retCapability:
            return readEqualizerInfo(&reader).map(T1Message.equalizerInfo) ?? .other(command: command)

        case EqualizerCommand.retParam, EqualizerCommand.notifyParam:
            return readEqualizer(&reader).map(T1Message.equalizer) ?? .other(command: command)

        case EqualizerCommand.retStatus, EqualizerCommand.notifyStatus:
            return readEqualizerAvailability(&reader).map(T1Message.equalizerAvailable) ?? .other(command: command)

        default:
            return .other(command: command)
        }
    }

    /// Table-2 mic-mute settings, from a SYSTEM_RET_PARAM or SYSTEM_NTFY_PARAM.
    static func readMicMute(_ reader: inout ByteReader) -> MicMuteSettings? {
        guard let buttonMutes = isOn(reader.u8()), let playsSound = isOn(reader.u8()) else { return nil }
        return MicMuteSettings(buttonMutes: buttonMutes, playsSound: playsSound)
    }
}

extension ByteReader {
    /// A length byte followed by that many UTF-8 bytes.
    mutating func prefixedString() -> String? {
        guard let length = u8(), let bytes = bytes(Int(length)) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
