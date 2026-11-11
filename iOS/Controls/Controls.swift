import AppIntents
import HeadphoneKit
import MDRKit
import SwiftUI
import WidgetKit

// The controls for Control Center, the Lock Screen and the Action button: one for everything the app can do. They
// show what the app last saved to the shared container, and their actions run in the app, which is the only place
// that can talk to the headphones.
//
// Each one says what's going on, not just on or off: its symbol is the headphones with whatever it controls drawn
// around or inside them, and its text names the mode, the level or the device.

@main
struct MultipointControls: WidgetBundle {
    var body: some Widget {
        NoiseControls().body
        SourceControls().body
        MicrophoneControls().body
    }
}

struct NoiseControls: WidgetBundle {
    var body: some Widget {
        NoiseCycleControl()
        NoiseCancellingControl()
        AmbientSoundControl()
        MoreAmbientControl()
        LessAmbientControl()
        AutoAmbientControl()
        FocusOnVoiceControl()
        EqualizerControl()
        EqualizerPresetControl()
    }
}

struct SourceControls: WidgetBundle {
    var body: some Widget {
        SwitchSourceControl()
        ThisPhoneControl()
        SwitchToDeviceControl()
        ConnectDeviceControl()
        AutoSwitchControl()
    }
}

struct MicrophoneControls: WidgetBundle {
    var body: some Widget {
        SidetoneControl()
        SpeakToChatControl()
        ChatSensitivityControl()
        ChatResumeControl()
        MuteButtonControl()
        MuteSoundControl()
    }
}

// A control's `kind` is for good: iOS remembers how a control looked in the picker under it, so changing a
// control's symbol later needs a new kind (and adding the control again).

/// The tint of a control that's on: graphite, to stay black and white like the app.
private let onTint = Color(white: 0.16)

/// What the app last read from the headphones.
struct StatusProvider: ControlValueProvider {
    var previewValue: HeadphoneStatus { HeadphoneStatus() }

    func currentValue() async throws -> HeadphoneStatus { SharedState.status }
}

private func ambientDetail(_ noise: NoiseControl) -> String {
    noise.adjustsAutomatically == true ? "Auto Level" : "Level \(noise.ambientLevel)"
}

/// A toggle for one of the on/off settings.
private func switchControl(kind: String, title: String, glyph: String, setting: HeadphoneSwitch,
                           description: String) -> some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "dev.pkhri.Multipoint.\(kind)", provider: StatusProvider()) { status in
        let value = setting.value(in: status)
        ControlWidgetToggle(title, isOn: value ?? false, action: SetSwitchIntent(setting: setting)) { isOn in
            Label(value == nil ? "Open Multipoint" : isOn ? "On" : "Off", image: glyph)
        }
        .tint(onTint)
    }
    .displayName(LocalizedStringResource(stringLiteral: title))
    .description(LocalizedStringResource(stringLiteral: description))
}

/// A button for one of the stepped settings; `text` says where it stands.
private func stepControl(kind: String, title: String, glyph: String, step: HeadphoneStep, description: String,
                         text: @escaping (HeadphoneStatus) -> String?) -> some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "dev.pkhri.Multipoint.\(kind)", provider: StatusProvider()) { status in
        ControlWidgetButton(action: StepSettingIntent(step: step)) {
            Label(text(status).map { "\(title) · \($0)" } ?? title, image: glyph)
        }
    }
    .displayName(LocalizedStringResource(stringLiteral: title))
    .description(LocalizedStringResource(stringLiteral: description))
}

// MARK: Noise control

/// One button for all three modes: shows the current one, and a tap moves to the next.
struct NoiseCycleControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.pkhri.Multipoint.noise-control", provider: StatusProvider()) { status in
            let noise = status.noiseControl
            ControlWidgetButton(action: CycleNoiseModeIntent()) {
                // Until the mode is known (and in the picker), the sealed headphones stand for the control.
                if let noise {
                    Label(noise.mode == .ambient ? "Ambient · \(ambientDetail(noise))" : noise.mode.title, image: noise.mode.glyph)
                } else {
                    Label("Noise Control", image: "headphones.sealed")
                }
            }
        }
        .displayName("Noise Control")
        .description("Shows whether the headphones are cancelling noise, letting sound in, or neither. Tap for the next mode.")
    }
}

struct NoiseCancellingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.pkhri.Multipoint.noise-cancelling-toggle", provider: StatusProvider()) { status in
            let mode = status.noiseControl?.mode
            ControlWidgetToggle("Noise Cancelling", isOn: mode == .noiseCancelling,
                                action: ToggleNoiseModeIntent(mode: .noiseCancelling)) { isOn in
                // When it's off, say what the headphones are doing instead.
                Label(isOn ? "On" : mode == .ambient ? "Off · Ambient" : "Off", image: "headphones.sealed")
            }
            .tint(onTint)
        }
        .displayName("Noise Cancelling")
        .description("Seal out the noise around you, or stop.")
    }
}

struct AmbientSoundControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.pkhri.Multipoint.ambient-sound-toggle", provider: StatusProvider()) { status in
            let noise = status.noiseControl
            ControlWidgetToggle("Ambient Sound", isOn: noise?.mode == .ambient, action: ToggleNoiseModeIntent(mode: .ambient)) { isOn in
                Label(isOn ? noise.map(ambientDetail) ?? "On" : noise?.mode == .noiseCancelling ? "Off · Cancelling" : "Off",
                      image: "headphones.waves")
            }
            .tint(onTint)
        }
        .displayName("Ambient Sound")
        .description("Let the sound around you into the headphones, or stop. Shows the level while it's on.")
    }
}

struct MoreAmbientControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        stepControl(kind: "ambient-more", title: "More Ambient", glyph: "headphones.waves.plus", step: .ambientMore,
                    description: "Let in more of the sound around you. Turns ambient sound on if it isn't.") {
            $0.noiseControl.map { "Level \($0.ambientLevel)" }
        }
    }
}

struct LessAmbientControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        stepControl(kind: "ambient-less", title: "Less Ambient", glyph: "headphones.waves.minus", step: .ambientLess,
                    description: "Let in less of the sound around you. Turns ambient sound on if it isn't.") {
            $0.noiseControl.map { "Level \($0.ambientLevel)" }
        }
    }
}

struct AutoAmbientControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        switchControl(kind: "ambient-auto", title: "Auto Ambient Level", glyph: "headphones.waves.auto", setting: .autoAmbient,
                      description: "Let the headphones set the ambient level from how loud it is around you.")
    }
}

struct FocusOnVoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        switchControl(kind: "focus-on-voice", title: "Focus on Voice", glyph: "headphones.waves.voice", setting: .focusOnVoice,
                      description: "In ambient sound, let voices through while holding back other noise.")
    }
}

// MARK: Equalizer

/// The current preset's name, as last read; nil until the app has read the equalizer.
private func equalizerPresetTitle(_ status: HeadphoneStatus) -> String? {
    guard let id = status.equalizer?.presetID else { return nil }
    return SharedState.presetNames.title(SharedState.equalizerPresets.first { $0.id == id } ?? EqualizerPreset(id: id))
}

/// Shows the equalizer's preset; a tap moves to the next one.
struct EqualizerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.pkhri.Multipoint.equalizer", provider: StatusProvider()) { status in
            ControlWidgetButton(action: CycleEqualizerPresetIntent()) {
                Label(equalizerPresetTitle(status).map { "Equalizer · \($0)" } ?? "Equalizer", image: "headphones.eq")
            }
        }
        .displayName("Equalizer")
        .description("Shows the equalizer's preset. Tap for the next one.")
    }
}

struct SelectEqualizerPresetIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Preset"
    static let isDiscoverable = false

    @Parameter(title: "Preset") var preset: EqualizerPresetEntity?
}

/// A button for one preset you choose; it says so while that preset is the one in use.
struct EqualizerPresetControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "dev.pkhri.Multipoint.equalizer-preset", intent: SelectEqualizerPresetIntent.self) { configuration in
            let preset = configuration.preset
            let inUse = preset?.presetID != nil && preset?.presetID == SharedState.status.equalizer?.presetID
            ControlWidgetButton(action: SetEqualizerPresetIntent(preset: preset)) {
                Label(preset.map { inUse ? "\($0.name) · In Use" : $0.name } ?? "Choose Preset", image: "headphones.eq")
            }
        }
        .displayName("Equalizer Preset")
        .description("Switch the equalizer to a preset you choose.")
        .promptsForUserConfiguration()
    }
}

// MARK: Audio source

/// Shows the device that's "wearing" the headphones; a tap hands them to the other one.
struct SwitchSourceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.pkhri.Multipoint.audio-source", provider: StatusProvider()) { status in
            let playing = status.playingDevice
            ControlWidgetButton(action: SwitchSourceIntent()) {
                Label(playing.map { "Playing from \($0.name)" } ?? "Switch Source", image: playing?.wornGlyph ?? "headphones.on.laptop")
            }
        }
        .displayName("Audio Source")
        .description("Shows which device the headphones are playing from. Tap to switch to the other one.")
    }
}

struct ThisPhoneControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.pkhri.Multipoint.on-this-iphone", provider: StatusProvider()) { status in
            let playing = status.playingDevice
            let isHere = playing != nil && playing?.address == SharedState.thisPhone(in: status)?.address
            ControlWidgetToggle("Headphones", isOn: isHere, action: PlayOnThisPhoneIntent()) { isOn in
                Label(isOn ? "On This \(SharedState.deviceName)" : playing.map { "On \($0.name)" } ?? "Elsewhere",
                      image: SharedState.deviceName == "iPad" ? "headphones.on.tablet" : "headphones.on.phone")
            }
            .tint(onTint)
        }
        .displayName("Headphones on This Device")
        .description("Bring the headphones' audio to this iPhone or iPad, or hand it back. Shows where it is now.")
    }
}

struct SelectDeviceIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Device"
    static let isDiscoverable = false

    @Parameter(title: "Device") var device: DeviceEntity?
}

struct SwitchToDeviceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "dev.pkhri.Multipoint.play-from-device", intent: SelectDeviceIntent.self) { configuration in
            ControlWidgetButton(action: SwitchToDeviceIntent(device: configuration.device)) {
                Label(configuration.device.map { "Play from \($0.name)" } ?? "Choose Device",
                      image: configuration.device?.wornGlyph ?? "headphones.on.device")
            }
        }
        .displayName("Play from Device")
        .description("Put the headphones on a device you choose.")
        .promptsForUserConfiguration()
    }
}

struct ConnectDeviceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "dev.pkhri.Multipoint.connect-device", intent: SelectDeviceIntent.self) { configuration in
            // The chosen device as the headphones last reported it.
            let device = configuration.device.flatMap { SharedState.status.device(matching: $0.id) }
            let name = device?.name ?? configuration.device?.name
            ControlWidgetToggle(name ?? "Choose Device", isOn: device?.isConnected ?? false,
                                action: SetDeviceConnectionIntent(device: configuration.device)) { isOn in
                Label(name == nil ? "Choose Device" : isOn ? "Connected" : "Not Connected", image: "headphones.link")
            }
            .tint(onTint)
        }
        .displayName("Connect Device")
        .description("Connect a device you choose to the headphones, or disconnect it.")
        .promptsForUserConfiguration()
    }
}

struct AutoSwitchControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        switchControl(kind: "auto-switch", title: "Auto-Switch", glyph: "headphones.swap", setting: .autoSwitch,
                      description: "Let the headphones follow whichever device starts playing, or stay where they are.")
    }
}

// MARK: Microphone

struct SidetoneControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        switchControl(kind: "sidetone", title: "Hear Your Voice", glyph: "headphones.mic", setting: .sidetone,
                      description: "Hear your own voice in the headphones during calls, so you don't talk too loudly.")
    }
}

struct SpeakToChatControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        switchControl(kind: "speak-to-chat", title: "Speak-to-Chat", glyph: "headphones.chat", setting: .speakToChat,
                      description: "Pause the music and let sound in when you start talking.")
    }
}

struct ChatSensitivityControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        stepControl(kind: "chat-sensitivity", title: "Chat Sensitivity", glyph: "headphones.chat.level", step: .chatSensitivity,
                    description: "How easily Speak-to-Chat hears you start talking. Tap for the next of Auto, High and Low.") {
            $0.speakToChatDetail?.sensitivity.title
        }
    }
}

struct ChatResumeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        stepControl(kind: "chat-resume", title: "Resume Music", glyph: "headphones.chat.timer", step: .chatResume,
                    description: "How soon after you stop talking the music comes back. Tap for the next of Short, Standard, Long and Don't Resume.") {
            $0.speakToChatDetail?.timeout.title
        }
    }
}

struct MuteButtonControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        switchControl(kind: "mute-button", title: "Mute with Button", glyph: "headphones.mic.slash", setting: .micMuteButton,
                      description: "Let a button on the headphones mute and unmute the mic during calls.")
    }
}

struct MuteSoundControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        switchControl(kind: "mute-sound", title: "Mute Sound", glyph: "headphones.mic.slash.sound", setting: .micMuteSound,
                      description: "Play a sound in the headphones when the mic is muted with the button.")
    }
}
