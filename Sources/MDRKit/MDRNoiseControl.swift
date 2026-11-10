/// Noise cancelling and ambient sound ("NC/ASM" in Sony's protocol), table 1.
///
/// Layouts mirror mos9527/SonyHeadphonesClient (`ProtocolV2T1.hpp`, the `NcAsm…Param` structs). Unlike the settings
/// in `MDRSettings.swift`, on/off here is the usual way round: 0x01 means on.

extension T1Function {
    /// AMBIENT_SOUND_MODE_LEVEL_ADJUSTMENT: ambient sound with a level, no noise cancelling.
    public static let ambientSound: UInt8 = 0x67
    /// MODE_NC_ASM_NOISE_CANCELLING_DUAL_AMBIENT_SOUND_MODE_LEVEL_ADJUSTMENT (WH-1000XM5 and similar).
    public static let noiseControl: UInt8 = 0x6B
    /// The same plus NOISE_ADAPTATION: ambient sound that adjusts its own level (WH-1000XM6, The ColleXion).
    public static let adaptiveNoiseControl: UInt8 = 0x6D
}

enum NoiseCommand {
    static let getParam: UInt8 = 0x66
    static let retParam: UInt8 = 0x67
    static let setParam: UInt8 = 0x68
    static let notifyParam: UInt8 = 0x69
}

/// Which of the protocol's NC/ASM message layouts the headphones use; the raw value is the `NcAsmInquiredType`.
public enum NoiseControlVariant: UInt8, Codable, Sendable {
    case ambientOnly = 0x22
    case dual = 0x17
    case adaptive = 0x19

    /// The richest layout among the functions the headphones advertise.
    public init?(supported functions: Set<UInt8>) {
        if functions.contains(T1Function.adaptiveNoiseControl) {
            self = .adaptive
        } else if functions.contains(T1Function.noiseControl) {
            self = .dual
        } else if functions.contains(T1Function.ambientSound) {
            self = .ambientOnly
        } else {
            return nil
        }
    }

    public var hasNoiseCancelling: Bool { self != .ambientOnly }
}

public enum NoiseControlMode: String, Codable, CaseIterable, Sendable {
    case noiseCancelling, ambient, off
}

public enum AdaptiveSensitivity: UInt8, Codable, CaseIterable, Sendable {
    case standard = 0x00, high = 0x01, low = 0x02
}

public struct NoiseControl: Equatable, Codable, Sendable {
    public static let ambientLevels: ClosedRange<UInt8> = 1...20

    public var variant: NoiseControlVariant
    /// False when both noise cancelling and ambient sound are off.
    public var isEnabled: Bool
    /// Which of the two is selected; the headphones remember it while `isEnabled` is false.
    public var isAmbient: Bool
    /// How much outside sound ambient mode lets in, 1…20.
    public var ambientLevel: UInt8
    /// Ambient mode favours voices over other noise.
    public var focusOnVoice: Bool
    /// Ambient mode sets its own level from the surroundings. Nil unless the variant is `.adaptive`.
    public var adjustsAutomatically: Bool?
    public var sensitivity: AdaptiveSensitivity?

    public init(variant: NoiseControlVariant, isEnabled: Bool, isAmbient: Bool, ambientLevel: UInt8, focusOnVoice: Bool,
                adjustsAutomatically: Bool? = nil, sensitivity: AdaptiveSensitivity? = nil) {
        self.variant = variant
        self.isEnabled = isEnabled
        self.isAmbient = isAmbient
        self.ambientLevel = ambientLevel
        self.focusOnVoice = focusOnVoice
        self.adjustsAutomatically = adjustsAutomatically
        self.sensitivity = sensitivity
    }

    public var mode: NoiseControlMode {
        get { !isEnabled ? .off : isAmbient || !variant.hasNoiseCancelling ? .ambient : .noiseCancelling }
        set {
            isEnabled = newValue != .off
            switch newValue {
            case .noiseCancelling: isAmbient = false
            case .ambient: isAmbient = true
            case .off: break
            }
        }
    }

    public var availableModes: [NoiseControlMode] {
        variant.hasNoiseCancelling ? [.noiseCancelling, .ambient, .off] : [.ambient, .off]
    }
}

extension MDRRequest {
    public static func noiseControl(_ variant: NoiseControlVariant) -> [UInt8] {
        [NoiseCommand.getParam, variant.rawValue]
    }

    /// - Parameter adjusting: true while a slider is still being dragged; the headphones apply the level right away
    ///   either way, and the official app sends a final message with it false.
    public static func setNoiseControl(_ value: NoiseControl, adjusting: Bool = false) -> [UInt8] {
        var payload: [UInt8] = [NoiseCommand.setParam, value.variant.rawValue, adjusting ? 0x00 : 0x01,
                                value.isEnabled ? 0x01 : 0x00]
        if value.variant.hasNoiseCancelling { payload.append(value.isAmbient ? 0x01 : 0x00) }
        payload += [value.focusOnVoice ? 0x01 : 0x00, value.ambientLevel]
        if value.variant == .adaptive {
            payload += [value.adjustsAutomatically == true ? 0x01 : 0x00, (value.sensitivity ?? .standard).rawValue]
        }
        return payload
    }
}

extension MDRParser {
    /// The body of an NCASM_RET_PARAM or NCASM_NTFY_PARAM, after the command byte. Returns nil for layouts this app
    /// doesn't use (older models, the button-assignment message).
    static func readNoiseControl(_ reader: inout ByteReader) -> (value: NoiseControl, adjusting: Bool)? {
        guard let variant = reader.u8().flatMap(NoiseControlVariant.init(rawValue:)),
              let changeStatus = reader.u8(), let enabled = reader.u8() else { return nil }
        var isAmbient = true
        if variant.hasNoiseCancelling {
            guard let mode = reader.u8() else { return nil }
            isAmbient = mode == 0x01
        }
        guard let voice = reader.u8(), let level = reader.u8() else { return nil }
        var value = NoiseControl(variant: variant, isEnabled: enabled == 0x01, isAmbient: isAmbient,
                                 ambientLevel: level, focusOnVoice: voice == 0x01)
        if variant == .adaptive {
            guard let automatic = reader.u8(), let sensitivity = reader.u8() else { return nil }
            value.adjustsAutomatically = automatic == 0x01
            value.sensitivity = AdaptiveSensitivity(rawValue: sensitivity) ?? .standard
        }
        return (value, changeStatus == 0x00)
    }
}
