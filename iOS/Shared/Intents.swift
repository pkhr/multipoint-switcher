import AppIntents
import HeadphoneKit
import MDRKit

// The actions behind the Control Center controls, the Shortcuts actions and Siri.
//
// They have to run in the app, not in the widget extension: only the app may open the accessory session to the
// headphones. Conforming to `LiveActivityIntent` is what makes iOS 18–26 launch the app in the background for a
// control (no Live Activity is involved); iOS 27 has `allowedExecutionTargets` to say so directly.

typealias HeadphoneIntent = LiveActivityIntent

enum NoiseModeOption: String, AppEnum {
    case noiseCancelling, ambient, off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Noise Control Mode"
    static let caseDisplayRepresentations: [NoiseModeOption: DisplayRepresentation] = [
        .noiseCancelling: DisplayRepresentation(title: "Noise Cancelling", image: .init(named: "headphones.sealed")),
        .ambient: DisplayRepresentation(title: "Ambient Sound", image: .init(named: "headphones.waves")),
        .off: DisplayRepresentation(title: "Off", image: .init(named: "headphones.plain")),
    ]

    var mode: NoiseControlMode { NoiseControlMode(rawValue: rawValue) ?? .off }
}

struct SetNoiseModeIntent: HeadphoneIntent {
    static let title: LocalizedStringResource = "Set Noise Control"
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static let description = IntentDescription("Switches the headphones to noise cancelling, ambient sound, or neither.")

    @Parameter(title: "Mode") var mode: NoiseModeOption

    static var parameterSummary: some ParameterSummary { Summary("Set headphones to \(\.$mode)") }

    init() {}
    init(mode: NoiseModeOption) { self.mode = mode }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await HeadphoneCommands.current().setNoiseMode(mode.mode)
        return .result()
    }
}

/// For the Noise Cancelling and Ambient Sound toggles: on selects that mode, off turns noise control off.
struct ToggleNoiseModeIntent: SetValueIntent, HeadphoneIntent {
    static let title: LocalizedStringResource = "Toggle Noise Control Mode"
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static let isDiscoverable = false

    @Parameter(title: "Mode") var mode: NoiseModeOption
    @Parameter(title: "On") var value: Bool

    init() {}
    init(mode: NoiseModeOption) { self.mode = mode }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await HeadphoneCommands.current().setNoiseMode(value ? mode.mode : .off)
        return .result()
    }
}

struct CycleNoiseModeIntent: HeadphoneIntent {
    static let title: LocalizedStringResource = "Change Noise Control"
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static let description = IntentDescription("Steps through noise cancelling, ambient sound and off.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<NoiseModeOption> {
        let mode = try await HeadphoneCommands.current().cycleNoiseMode()
        return .result(value: NoiseModeOption(rawValue: mode.rawValue) ?? .off)
    }
}

struct SwitchSourceIntent: HeadphoneIntent {
    static let title: LocalizedStringResource = "Switch Headphones to Other Device"
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static let description = IntentDescription("Moves the headphones' audio to the other device they're connected to.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await HeadphoneCommands.current().switchToNextDevice())
    }
}

/// A device paired with the headphones, as last read from them.
struct DeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Device"
    static let defaultQuery = DeviceQuery()

    /// The Bluetooth address, as the headphones report it.
    let id: String
    let name: String
    let symbolName: String
    /// The app's symbol of this kind of device wearing the headphones.
    let wornGlyph: String

    init(_ device: PairedDevice) {
        id = device.address
        name = device.name
        symbolName = device.symbolName
        wornGlyph = device.wornGlyph
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbolName))
    }
}

/// Answers from the shared copy of the device list, so it works in the widget extension too.
struct DeviceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DeviceEntity] {
        SharedState.status.devices.filter { identifiers.contains($0.address) }.map(DeviceEntity.init)
    }

    func suggestedEntities() async throws -> [DeviceEntity] {
        SharedState.status.devices.map(DeviceEntity.init)
    }
}

struct SwitchToDeviceIntent: HeadphoneIntent {
    static let title: LocalizedStringResource = "Switch Headphones to Device"
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static let description = IntentDescription("Makes one of the headphones' connected devices the audio source.")

    @Parameter(title: "Device") var device: DeviceEntity?

    static var parameterSummary: some ParameterSummary { Summary("Play headphones from \(\.$device)") }

    init() {}
    init(device: DeviceEntity?) { self.device = device }

    @MainActor
    func perform() async throws -> some IntentResult {
        // A control can't stop to ask, so a missing choice is an error rather than a question.
        guard let device else { throw HeadphoneError("Choose a device for this control first.") }
        try await HeadphoneCommands.current().switchPlayback(toAddress: device.id)
        return .result()
    }
}

/// For the "This iPhone" toggle: on brings the audio here, off hands it to the other device.
struct PlayOnThisPhoneIntent: SetValueIntent, HeadphoneIntent {
    static let title: LocalizedStringResource = "Play Headphones from This iPhone"
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static let isDiscoverable = false

    @Parameter(title: "On") var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        let commands = try HeadphoneCommands.current()
        if value {
            guard let phone = SharedState.thisPhone(in: SharedState.status) else {
                throw HeadphoneError("Open Multipoint and choose which device is this iPhone.")
            }
            try await commands.switchPlayback(toAddress: phone.address)
        } else {
            _ = try await commands.switchToNextDevice()
        }
        return .result()
    }
}

// MARK: Settings

/// The headphones' on/off settings.
enum HeadphoneSwitch: String, AppEnum, CaseIterable {
    case autoAmbient, focusOnVoice, autoSwitch, sidetone, speakToChat, micMuteButton, micMuteSound

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Headphone Setting"
    static let caseDisplayRepresentations: [HeadphoneSwitch: DisplayRepresentation] = [
        .autoAmbient: DisplayRepresentation(title: "Auto Ambient Level", image: .init(named: "headphones.waves.auto")),
        .focusOnVoice: DisplayRepresentation(title: "Focus on Voice", image: .init(named: "headphones.waves.voice")),
        .autoSwitch: DisplayRepresentation(title: "Auto-Switch", image: .init(named: "headphones.swap")),
        .sidetone: DisplayRepresentation(title: "Hear Your Voice on Calls", image: .init(named: "headphones.mic")),
        .speakToChat: DisplayRepresentation(title: "Speak-to-Chat", image: .init(named: "headphones.chat")),
        .micMuteButton: DisplayRepresentation(title: "Mute Mic with Headphone Button", image: .init(named: "headphones.mic.slash")),
        .micMuteSound: DisplayRepresentation(title: "Sound When Mic Is Muted", image: .init(named: "headphones.mic.slash.sound")),
    ]

    /// What it's set to, or nil if these headphones don't have it (or it hasn't been read yet).
    func value(in status: HeadphoneStatus) -> Bool? {
        switch self {
        case .autoAmbient: return status.noiseControl?.adjustsAutomatically
        case .focusOnVoice: return status.noiseControl?.focusOnVoice
        case .autoSwitch: return status.autoSwitch
        case .sidetone: return status.sidetone
        case .speakToChat: return status.speakToChat
        case .micMuteButton: return status.micMute?.buttonMutes
        case .micMuteSound: return status.micMute?.playsSound
        }
    }
}

struct SetSwitchIntent: SetValueIntent, HeadphoneIntent {
    static let title: LocalizedStringResource = "Turn Headphone Setting On or Off"
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static let description = IntentDescription("Turns one of the headphones' settings on or off.")

    @Parameter(title: "Setting") var setting: HeadphoneSwitch
    @Parameter(title: "On") var value: Bool

    static var parameterSummary: some ParameterSummary { Summary("Turn \(\.$setting) \(\.$value)") }

    init() {}
    init(setting: HeadphoneSwitch) { self.setting = setting }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await HeadphoneCommands.current().setSwitch(setting, on: value)
        return .result()
    }
}

/// Settings that move in steps: a tap takes them one step on.
enum HeadphoneStep: String, AppEnum {
    case ambientMore, ambientLess, chatSensitivity, chatResume

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Headphone Adjustment"
    static let caseDisplayRepresentations: [HeadphoneStep: DisplayRepresentation] = [
        .ambientMore: DisplayRepresentation(title: "More Ambient Sound", image: .init(named: "headphones.waves.plus")),
        .ambientLess: DisplayRepresentation(title: "Less Ambient Sound", image: .init(named: "headphones.waves.minus")),
        .chatSensitivity: DisplayRepresentation(title: "Next Speak-to-Chat Sensitivity", image: .init(named: "headphones.chat.level")),
        .chatResume: DisplayRepresentation(title: "Next Resume-Music Delay", image: .init(named: "headphones.chat.timer")),
    ]
}

struct StepSettingIntent: HeadphoneIntent {
    static let title: LocalizedStringResource = "Adjust Headphone Setting"
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static let description = IntentDescription("Lets in more or less ambient sound, or moves a Speak-to-Chat setting to its next value.")

    @Parameter(title: "Adjustment") var step: HeadphoneStep

    static var parameterSummary: some ParameterSummary { Summary("\(\.$step)") }

    init() {}
    init(step: HeadphoneStep) { self.step = step }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await HeadphoneCommands.current().step(step))
    }
}

/// Connects a paired device to the headphones, or disconnects it.
struct SetDeviceConnectionIntent: SetValueIntent, HeadphoneIntent {
    static let title: LocalizedStringResource = "Connect Device to Headphones"
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static let description = IntentDescription("Connects one of the headphones' paired devices to them, or disconnects it.")

    @Parameter(title: "Device") var device: DeviceEntity?
    @Parameter(title: "Connected") var value: Bool

    init() {}
    init(device: DeviceEntity?) { self.device = device }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let device else { throw HeadphoneError("Choose a device for this control first.") }
        try await HeadphoneCommands.current().setDevice(address: device.id, connected: value)
        return .result()
    }
}

// MARK: Equalizer

/// One of the equalizer's presets, as the headphones listed them.
struct EqualizerPresetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Equalizer Preset"
    static let defaultQuery = EqualizerPresetQuery()

    /// The protocol's preset number, as text.
    let id: String
    let name: String

    init(_ preset: EqualizerPreset) {
        id = String(preset.id)
        name = SharedState.presetNames.title(preset)
    }

    var presetID: UInt8? { UInt8(id) }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(named: "headphones.eq"))
    }
}

/// Answers from the shared copy of the preset list, so it works in the widget extension too.
struct EqualizerPresetQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [EqualizerPresetEntity] {
        SharedState.equalizerPresets.map(EqualizerPresetEntity.init).filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [EqualizerPresetEntity] {
        SharedState.equalizerPresets.map(EqualizerPresetEntity.init)
    }
}

struct SetEqualizerPresetIntent: HeadphoneIntent {
    static let title: LocalizedStringResource = "Set Equalizer Preset"
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static let description = IntentDescription("Switches the headphones' equalizer to one of its presets.")

    @Parameter(title: "Preset") var preset: EqualizerPresetEntity?

    static var parameterSummary: some ParameterSummary { Summary("Set headphones' equalizer to \(\.$preset)") }

    init() {}
    init(preset: EqualizerPresetEntity?) { self.preset = preset }

    @MainActor
    func perform() async throws -> some IntentResult {
        // A control can't stop to ask, so a missing choice is an error rather than a question.
        guard let id = preset?.presetID else { throw HeadphoneError("Choose a preset for this control first.") }
        _ = try await HeadphoneCommands.current().setEqualizerPreset(id: id)
        return .result()
    }
}

struct CycleEqualizerPresetIntent: HeadphoneIntent {
    static let title: LocalizedStringResource = "Next Equalizer Preset"
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static let description = IntentDescription("Moves the headphones' equalizer to its next preset.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await HeadphoneCommands.current().cycleEqualizerPreset())
    }
}
