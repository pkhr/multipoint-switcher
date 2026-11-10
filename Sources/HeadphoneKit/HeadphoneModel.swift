import Foundation
import MDRKit

/// What a pair of headphones can do. It only changes with a firmware update, so it's read once and reused by later
/// connections to keep them short.
public struct HeadphoneCapabilities: Equatable, Codable, Sendable {
    public var supportedT1: Set<UInt8>
    public var supportedT2: Set<UInt8>
    /// The model-specific switches the headphones describe themselves, e.g. sidetone.
    public var generalSettings: [GeneralSettingInfo]
    /// The equalizer's presets and bands; nil if the headphones have none, or didn't describe it.
    public var equalizer: EqualizerInfo?
    /// Whether the equalizer has been asked about. Nil in capabilities saved before the app knew to ask.
    public var equalizerProbed: Bool?

    public init(supportedT1: Set<UInt8> = [], supportedT2: Set<UInt8> = [], generalSettings: [GeneralSettingInfo] = []) {
        self.supportedT1 = supportedT1
        self.supportedT2 = supportedT2
        self.generalSettings = generalSettings
    }

    public var supportsDeviceList: Bool {
        !supportedT2.isDisjoint(with: [T2Function.pairingClassic, T2Function.pairingWithClassOfDeviceClassic,
                                       T2Function.pairingWithClassOfDeviceLE])
    }

    public var supportsAutoSwitch: Bool { supportedT2.contains(T2Function.sourceSwitchControl) }
    public var noiseControlVariant: NoiseControlVariant? { NoiseControlVariant(supported: supportedT1) }
    public var sidetoneIndex: UInt8? { generalSettings.first(where: \.isSidetone)?.index }
    public var supportsSpeakToChat: Bool { supportedT1.contains(T1Function.speakToChat) }
    public var supportsMicMute: Bool { supportedT2.contains(T2Function.micMuteByHeadphones) }
    public var equalizerVariant: EqualizerVariant? { EqualizerVariant(supported: supportedT1) }

    var pairingListType: PeripheralInquiredType {
        supportedT2.contains(T2Function.pairingWithClassOfDeviceClassic) || supportedT2.contains(T2Function.pairingWithClassOfDeviceLE)
            ? .pairingWithClassOfDevice : .pairingClassic
    }
}

/// Everything the headphones have told us. Fields are nil until read, or when the headphones don't have the feature.
public struct HeadphoneStatus: Equatable, Codable, Sendable {
    public var devices: [PairedDevice] = []
    /// Whether the headphones may hand playback to the other device on their own when it starts playing.
    public var autoSwitch: Bool?
    public var noiseControl: NoiseControl?
    /// Plays your own voice back in the headphones during calls.
    public var sidetone: Bool?
    public var speakToChat: Bool?
    public var speakToChatDetail: SpeakToChatDetail?
    public var micMute: MicMuteSettings?
    public var equalizer: Equalizer?
    /// False while the headphones won't let the equalizer be changed, e.g. during a call.
    public var equalizerAvailable: Bool?

    public init() {}

    public var connectedDevices: [PairedDevice] { devices.filter(\.isConnected) }
    public var playingDevice: PairedDevice? { devices.first(where: \.isPlaying) }

    /// The connected device after the one that's playing, for "switch to the other device".
    public var nextDevice: PairedDevice? {
        let connected = connectedDevices
        guard connected.count > 1 else { return nil }
        let current = connected.firstIndex(where: \.isPlaying) ?? -1
        return connected[(current + 1) % connected.count]
    }

    public func device(matching address: String) -> PairedDevice? {
        let normalized = normalizeAddress(address)
        return devices.first { $0.normalizedAddress == normalized }
    }
}

/// The last known state, for showing something right away and for the next connection to build on.
public struct HeadphoneSnapshot: Equatable, Codable, Sendable {
    public var capabilities: HeadphoneCapabilities?
    public var status: HeadphoneStatus
    /// When the device list was last read from the headphones.
    public var date: Date?

    public init(capabilities: HeadphoneCapabilities? = nil, status: HeadphoneStatus = HeadphoneStatus(), date: Date? = nil) {
        self.capabilities = capabilities
        self.status = status
        self.date = date
    }
}

extension PairedDevice {
    public var symbolName: String {
        switch kind {
        case .laptop: return "laptopcomputer"
        case .desktop: return "desktopcomputer"
        case .tablet: return "ipad"
        case .phone: return "iphone"
        case .speaker: return "hifispeaker"
        case .tv: return "tv"
        case .watch: return "applewatch"
        case .unknown: return "dot.radiowaves.left.and.right"
        }
    }
}

extension NoiseControlMode {
    public var title: String {
        switch self {
        case .noiseCancelling: return "Noise Cancelling"
        case .ambient: return "Ambient Sound"
        case .off: return "Off"
        }
    }

    /// For tight spaces, e.g. under an icon.
    public var shortTitle: String {
        switch self {
        case .noiseCancelling: return "Noise Cancelling"
        case .ambient: return "Ambient"
        case .off: return "Off"
        }
    }

    public var symbolName: String {
        switch self {
        case .noiseCancelling: return "person.fill"
        case .ambient: return "person.wave.2.fill"
        case .off: return "circle.slash"
        }
    }
}
