/// The equalizer ("EQ/EBB" in Sony's protocol), table 1.
///
/// Layouts mirror mos9527/SonyHeadphonesClient (`ProtocolV2T1.hpp`, the `EqEbb…` structs). The headphones list their
/// presets and say how many bands there are and how many positions each band has; a band's value travels as a step
/// counted from the bottom, so the middle step is flat.

extension T1Function {
    /// PRESET_EQ: presets, and bands you can set yourself.
    public static let equalizer: UInt8 = 0x50
    /// PRESET_EQ_NON_CUSTOMIZABLE: presets only.
    public static let fixedEqualizer: UInt8 = 0x52
    /// PRESET_EQ_AND_ERRORCODE: as PRESET_EQ, and the headphones say why when it's unavailable (WH-1000XM6,
    /// The ColleXion).
    public static let equalizerWithReasons: UInt8 = 0x57
}

enum EqualizerCommand {
    static let getCapability: UInt8 = 0x50
    static let retCapability: UInt8 = 0x51
    static let getStatus: UInt8 = 0x52
    static let retStatus: UInt8 = 0x53
    static let notifyStatus: UInt8 = 0x55
    static let getParam: UInt8 = 0x56
    static let retParam: UInt8 = 0x57
    static let setParam: UInt8 = 0x58
    static let notifyParam: UInt8 = 0x59

    /// The inquired type the values are read and written under, whichever variant the headphones advertise.
    static let presetType: UInt8 = 0x00
    /// The variants whose messages share one layout. (0x03, with Sony's "ULT" bass mode, has another.)
    static let presetTypes: Set<UInt8> = [0x00, 0x02, 0x04]
}

/// Which equalizer the headphones advertise; the raw value is the `EqEbbInquiredType` to ask about its presets with.
public enum EqualizerVariant: UInt8, Codable, Sendable {
    case customizable = 0x00
    case presetsOnly = 0x02
    case customizableWithReasons = 0x04

    public init?(supported functions: Set<UInt8>) {
        if functions.contains(T1Function.equalizer) {
            self = .customizable
        } else if functions.contains(T1Function.fixedEqualizer) {
            self = .presetsOnly
        } else if functions.contains(T1Function.equalizerWithReasons) {
            self = .customizableWithReasons
        } else {
            return nil
        }
    }
}

public struct EqualizerPreset: Equatable, Codable, Sendable, Identifiable {
    public static let off: UInt8 = 0x00
    /// "Manual" in Sony's app: the bands as you last set them.
    public static let manual: UInt8 = 0xA0

    public var id: UInt8
    /// What the headphones call it; often empty.
    public var name: String

    public init(id: UInt8, name: String = "") {
        self.id = id
        self.name = name
    }

    /// Manual and Custom 1…5: the presets whose bands can be changed.
    public var isCustom: Bool { (0xA0...0xA5).contains(id) }

    public var title: String {
        if let known = Self.titles[id] { return known }
        if !name.isEmpty {
            // Some firmware sends an identifier ("EQ_PRESET_NAME") rather than a name.
            guard name.contains("_") else { return name }
            return name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
        return "Preset \(id)"
    }

    /// Names as Sony's app shows them, by `EqPresetId`.
    private static let titles: [UInt8: String] = [
        0x00: "Off", 0x01: "Rock", 0x02: "Pop", 0x03: "Jazz", 0x04: "Dance", 0x05: "EDM", 0x06: "R&B / Hip-Hop",
        0x07: "Acoustic", 0x10: "Bright", 0x11: "Excited", 0x12: "Mellow", 0x13: "Relaxed", 0x14: "Vocal",
        0x15: "Treble Boost", 0x16: "Bass Boost", 0x17: "Speech", 0x20: "Gaming", 0x21: "FPS 1", 0x22: "FPS 2",
        0x23: "FPS 3", 0x30: "Heavy", 0x31: "Clear", 0x32: "Hard", 0x33: "Soft", 0xA0: "Manual", 0xA1: "Custom 1",
        0xA2: "Custom 2", 0xA3: "Custom 3", 0xA4: "Custom 4", 0xA5: "Custom 5",
    ]
}

/// What the headphones' equalizer offers. It doesn't change, so it's read once.
public struct EqualizerInfo: Equatable, Codable, Sendable {
    public var variant: EqualizerVariant
    public var bandCount: Int
    /// How many positions each band has, e.g. 21 for −10…+10.
    public var stepCount: Int
    public var presets: [EqualizerPreset]

    public init(variant: EqualizerVariant, bandCount: Int, stepCount: Int, presets: [EqualizerPreset]) {
        self.variant = variant
        self.bandCount = bandCount
        self.stepCount = stepCount
        self.presets = presets
    }

    public var isCustomizable: Bool { variant != .presetsOnly && bandCount > 0 && stepCount > 1 }
    /// The step that means flat; levels are counted from it.
    public var flatStep: Int { (stepCount - 1) / 2 }
    public var levels: ClosedRange<Int> { -flatStep...(stepCount - 1 - flatStep) }

    public func preset(_ id: UInt8) -> EqualizerPreset? { presets.first { $0.id == id } }

    /// The preset that changing a band switches to, when the current one can't be changed.
    public var customPreset: EqualizerPreset? {
        preset(EqualizerPreset.manual) ?? presets.first(where: \.isCustom)
    }

    /// What each band is. Sony uses two layouts: Clear Bass plus five bands, or ten bands.
    public var bandLabels: [String] {
        switch bandCount {
        case 6: return ["Bass", "400", "1k", "2.5k", "6.3k", "16k"]
        case 10: return ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
        default: return (1...max(bandCount, 1)).map(String.init)
        }
    }
}

/// The equalizer's current setting.
public struct Equalizer: Equatable, Codable, Sendable {
    public var presetID: UInt8
    /// Each band's position, counted from the bottom. Empty if the headphones didn't report the bands.
    public var steps: [UInt8]

    public init(presetID: UInt8, steps: [UInt8] = []) {
        self.presetID = presetID
        self.steps = steps
    }

    /// The bands as levels around flat, e.g. −6…+6.
    public func levels(in info: EqualizerInfo) -> [Int] {
        steps.map { Int($0) - info.flatStep }
    }

    public mutating func setLevel(_ level: Int, band: Int, in info: EqualizerInfo) {
        guard steps.indices.contains(band) else { return }
        let clamped = min(max(level, info.levels.lowerBound), info.levels.upperBound)
        steps[band] = UInt8(clamping: clamped + info.flatStep)
    }
}

extension MDRRequest {
    /// The presets, and the number of bands and steps. The last byte asks for names in English.
    public static func equalizerInfo(_ variant: EqualizerVariant) -> [UInt8] {
        [EqualizerCommand.getCapability, variant.rawValue, 0x01]
    }

    public static let equalizer: [UInt8] = [EqualizerCommand.getParam, EqualizerCommand.presetType]
    public static func equalizerAvailability(_ variant: EqualizerVariant) -> [UInt8] {
        [EqualizerCommand.getStatus, variant.rawValue]
    }

    /// Selects a preset; the headphones then use that preset's own bands.
    public static func selectEqualizerPreset(_ id: UInt8) -> [UInt8] {
        [EqualizerCommand.setParam, EqualizerCommand.presetType, id, 0x00]
    }

    /// Sets the bands of a custom preset, and selects it.
    public static func setEqualizer(_ value: Equalizer) -> [UInt8] {
        [EqualizerCommand.setParam, EqualizerCommand.presetType, value.presetID, UInt8(clamping: value.steps.count)] + value.steps
    }
}

extension MDRParser {
    /// The body of an EQEBB_RET_CAPABILITY after the command byte: bands, steps, then the presets.
    static func readEqualizerInfo(_ reader: inout ByteReader) -> EqualizerInfo? {
        guard let variant = reader.u8().flatMap(EqualizerVariant.init(rawValue:)),
              let bands = reader.u8(), let steps = reader.u8(), let count = reader.u8() else { return nil }
        var presets: [EqualizerPreset] = []
        for _ in 0..<count {
            guard let id = reader.u8(), let name = reader.prefixedString() else { return nil }
            presets.append(EqualizerPreset(id: id, name: name))
        }
        return EqualizerInfo(variant: variant, bandCount: Int(bands), stepCount: Int(steps), presets: presets)
    }

    /// The body of an EQEBB_RET_PARAM or EQEBB_NTFY_PARAM after the command byte: the preset, then the bands.
    static func readEqualizer(_ reader: inout ByteReader) -> Equalizer? {
        guard let type = reader.u8(), EqualizerCommand.presetTypes.contains(type), let preset = reader.u8() else { return nil }
        // A notification about a preset change may leave the bands out.
        guard let count = reader.u8() else { return Equalizer(presetID: preset) }
        guard let steps = reader.bytes(Int(count)) else { return nil }
        return Equalizer(presetID: preset, steps: steps)
    }

    /// The body of an EQEBB_RET_STATUS or EQEBB_NTFY_STATUS: whether the equalizer can be used right now (it can't
    /// during a call, for one). As elsewhere in the status messages, 0x00 means enabled.
    static func readEqualizerAvailability(_ reader: inout ByteReader) -> Bool? {
        guard let type = reader.u8(), EqualizerCommand.presetTypes.contains(type), let state = reader.u8() else { return nil }
        return state == 0x00
    }
}
