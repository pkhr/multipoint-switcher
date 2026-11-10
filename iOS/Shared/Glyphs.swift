import HeadphoneKit
import MDRKit

// The app's own symbols, drawn by Tools/make-symbols.py into Symbols.xcassets. They say more at a glance than
// stock ones: the headphones sealed in a bubble or with sound coming in, and the device that's "wearing" them.

extension NoiseControlMode {
    var glyph: String {
        switch self {
        case .noiseCancelling: return "headphones.sealed"
        case .ambient: return "headphones.waves"
        case .off: return "headphones.plain"
        }
    }
}

extension DeviceKind {
    /// This kind of device with the headphones on: it's the one they play from.
    var wornGlyph: String {
        switch self {
        case .phone: return "headphones.on.phone"
        case .laptop, .desktop: return "headphones.on.laptop"
        case .tablet: return "headphones.on.tablet"
        case .speaker, .tv, .watch, .unknown: return "headphones.on.device"
        }
    }
}

extension PairedDevice {
    var wornGlyph: String { kind.wornGlyph }
}

extension SpeakToChatSensitivity {
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .high: return "High"
        case .low: return "Low"
        }
    }
}

extension SpeakToChatTimeout {
    /// How long after you stop talking the music comes back.
    var title: String {
        switch self {
        case .short: return "Short"
        case .standard: return "Standard"
        case .long: return "Long"
        case .never: return "Don't Resume"
        }
    }
}
