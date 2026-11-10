import HeadphoneKit
import MDRKit
import SwiftUI

struct ContentView: View {
    @Environment(HeadphoneStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.backdrop
            ScrollView {
                VStack(spacing: 22) {
                    Header()
                    Hero()
                    if !store.isReachable {
                        NotConnectedCard()
                    } else {
                        if case let .failed(reason) = store.link {
                            FailureCard(reason: reason)
                        }
                        if let noise = store.status.noiseControl {
                            NoiseControlSection(noise: noise)
                        }
                        if let info = store.capabilities?.equalizer, let equalizer = store.status.equalizer {
                            EqualizerSection(info: info, value: equalizer)
                        }
                        if !store.status.devices.isEmpty {
                            SourceSection()
                            OptionsSection()
                        }
                        MicrophoneSection()
                        if store.capabilities != nil {
                            Text("To change these without opening the app, add Multipoint's controls to Control Center: swipe down from the top-right corner, touch and hold an empty area, then tap Add a Control.")
                                .font(.footnote)
                                .foregroundStyle(Theme.tertiaryText)
                                .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .tint(.white)
        .toggleStyle(MonoToggleStyle())
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase, initial: true) { _, phase in
            store.setVisible(phase == .active)
        }
        .alert("Headphones", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.notice ?? "")
        }
    }
}

// MARK: Header and hero

private struct Header: View {
    @Environment(HeadphoneStore.self) private var store

    var body: some View {
        VStack(spacing: 8) {
            Text(store.headphonesName ?? "Headphones")
                .font(.system(size: 26, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 7) {
                if store.isReachable, store.link == .connecting {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(store.isReachable ? Color.white : Theme.tertiaryText)
                        .frame(width: 6, height: 6)
                        .shadow(color: store.isReachable ? .white.opacity(0.9) : .clear, radius: 4)
                }
                Text(statusText.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    private var statusText: String {
        guard store.isReachable else { return "Not connected" }
        switch store.link {
        case .connecting: return "Connecting"
        case .failed: return "Can't reach headphones"
        case .live, .idle: return "Connected"
        }
    }
}

/// The photograph of the headphones, with the two things you change most right under it.
private struct Hero: View {
    @Environment(HeadphoneStore.self) private var store

    var body: some View {
        let noise = store.isReachable ? store.status.noiseControl : nil
        VStack(spacing: 6) {
            Image("Headphones")
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 370)
                .background {
                    // A pool of studio light on the backdrop, so the black headphones keep their outline.
                    RadialGradient(colors: [.white.opacity(0.17), .white.opacity(0.05), .clear], center: .center,
                                   startRadius: 10, endRadius: 230)
                        .frame(width: 460, height: 460)
                }
                .saturation(0)
                .opacity(store.isReachable ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.4), value: store.isReachable)
                .accessibilityHidden(true)
            if store.isReachable {
                HStack(spacing: 12) {
                    HeroControl(caption: "Mode", title: noise.map { $0.mode == .noiseCancelling ? "Cancelling" : $0.mode.shortTitle } ?? "—", glyph: noise?.mode.glyph ?? "headphones.plain",
                                isActive: noise.map { $0.mode != .off } ?? false, isEnabled: noise != nil, action: cycleNoiseMode)
                    let playing = store.status.playingDevice
                    HeroControl(caption: "Source", title: playing?.name ?? "—", glyph: playing?.wornGlyph ?? "headphones.plain",
                                isActive: playing != nil, isEnabled: store.status.nextDevice != nil, action: store.switchToOtherDevice)
                }
                .padding(.top, 6)
            }
        }
    }

    private func cycleNoiseMode() {
        guard var noise = store.status.noiseControl else { return }
        let modes = noise.availableModes
        noise.mode = modes[((modes.firstIndex(of: noise.mode) ?? -1) + 1) % modes.count]
        store.setNoiseControl(noise)
    }
}

private struct HeroControl: View {
    let caption: String
    let title: String
    let glyph: String
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(glyph)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : Theme.secondaryText)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(caption.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.white.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(isActive ? 0.22 : 0.09)))
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        .accessibilityLabel("\(caption): \(title)")
        .accessibilityHint("Changes to the next one")
    }
}

private struct NotConnectedCard: View {
    @Environment(HeadphoneStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            Text("Connect your Sony headphones to this iPhone in Settings › Bluetooth. If Sound Connect is open, close it: only one app can control the headphones at a time.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button {
                store.retry()
            } label: {
                Text("Check Again")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            Button("Look for Headphones…") { store.showAccessoryPicker() }
                .font(.subheadline.weight(.medium))
        }
        .card(padding: 20)
    }
}

private struct FailureCard: View {
    @Environment(HeadphoneStore.self) private var store
    let reason: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
            Text(reason).font(.subheadline)
            Spacer(minLength: 0)
            Button("Try Again") { store.retry() }
                .font(.subheadline.weight(.semibold))
        }
        .card()
    }
}

// MARK: Noise control

private struct NoiseControlSection: View {
    @Environment(HeadphoneStore.self) private var store
    let noise: NoiseControl
    @State private var draggedLevel: Double?

    var body: some View {
        VStack(spacing: 10) {
            SectionLabel(text: "Noise Control")
            HStack(spacing: 10) {
                ForEach(noise.availableModes, id: \.self) { mode in
                    ModeTile(mode: mode, isSelected: noise.mode == mode) {
                        var changed = noise
                        changed.mode = mode
                        store.setNoiseControl(changed)
                    }
                }
            }
            if noise.mode == .ambient {
                ambientCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: noise.mode)
    }

    private var ambientCard: some View {
        let automatic = noise.adjustsAutomatically == true
        let levels = NoiseControl.ambientLevels
        let level = draggedLevel ?? Double(noise.ambientLevel)
        return VStack(spacing: 14) {
            VStack(spacing: 8) {
                HStack {
                    Text("Ambient Level")
                    Spacer()
                    Text(automatic ? "Auto" : "\(Int(level))")
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                }
                .font(.system(size: 15, weight: .medium))
                Slider(value: Binding(get: { level }, set: { newLevel in
                    draggedLevel = newLevel
                    send(level: newLevel, adjusting: true)
                }), in: Double(levels.lowerBound)...Double(levels.upperBound), step: 1) {
                    Text("Ambient sound level")
                } minimumValueLabel: {
                    Image(systemName: "ear").foregroundStyle(Theme.secondaryText)
                } maximumValueLabel: {
                    Image(systemName: "ear.and.waveform").foregroundStyle(Theme.secondaryText)
                } onEditingChanged: { editing in
                    guard !editing, let final = draggedLevel else { return }
                    send(level: final, adjusting: false)
                    draggedLevel = nil
                }
                .disabled(automatic)
                .opacity(automatic ? 0.45 : 1)
            }
            if noise.adjustsAutomatically != nil {
                RowDivider()
                Toggle("Adjust Level Automatically", isOn: Binding(get: { automatic }, set: { on in
                    var changed = noise
                    changed.adjustsAutomatically = on
                    store.setNoiseControl(changed)
                }))
            }
            RowDivider()
            Toggle("Focus on Voice", isOn: Binding(get: { noise.focusOnVoice }, set: { on in
                var changed = noise
                changed.focusOnVoice = on
                store.setNoiseControl(changed)
            }))
        }
        .font(.system(size: 15, weight: .medium))
        .card()
    }

    private func send(level: Double, adjusting: Bool) {
        var changed = noise
        changed.ambientLevel = UInt8(clamping: Int(level.rounded()))
        store.setNoiseControl(changed, adjusting: adjusting)
    }
}

private struct ModeTile: View {
    let mode: NoiseControlMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(mode.glyph)
                    .font(.system(size: 27, weight: .medium))
                    .frame(height: 32)
                Text(mode.shortTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            // Selected is the inverse: black on white.
            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.72))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .padding(.horizontal, 6)
            .background(isSelected ? Color.white : Theme.card, in: Theme.cardShape)
            .overlay(Theme.cardShape.strokeBorder(isSelected ? .clear : Theme.hairline))
            .shadow(color: isSelected ? .white.opacity(0.18) : .clear, radius: 12)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: Equalizer

private struct EqualizerSection: View {
    @Environment(HeadphoneStore.self) private var store
    let info: EqualizerInfo
    let value: Equalizer

    var body: some View {
        let available = store.status.equalizerAvailable != false
        let levels = value.levels(in: info)
        VStack(spacing: 10) {
            SectionLabel(text: "Equalizer")
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(info.presets) { preset in
                            PresetChip(title: preset.title, isSelected: preset.id == value.presetID) {
                                store.selectEqualizerPreset(preset.id)
                            }
                            .id(preset.id)
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(value.presetID, anchor: .center) }
                .onChange(of: value.presetID) { _, id in
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
            if info.isCustomizable, !levels.isEmpty {
                let labels = info.bandLabels
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(levels.enumerated()), id: \.offset) { band, level in
                        BandSlider(label: band < labels.count ? labels[band] : "\(band + 1)", level: level, range: info.levels) { level, adjusting in
                            store.setEqualizerLevel(level, band: band, adjusting: adjusting)
                        }
                    }
                }
                .card(padding: 12)
            }
            if !available {
                Text("The headphones won't change the equalizer right now, for example during a call.")
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            } else if info.isCustomizable, info.preset(value.presetID)?.isCustom != true, let custom = info.customPreset {
                Text("Moving a band switches to \(custom.title), starting from these levels.")
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .disabled(!available)
        .opacity(available ? 1 : 0.5)
    }
}

private struct PresetChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                // Selected is the inverse: black on white.
                .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.78))
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(isSelected ? Color.white : Theme.card, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? .clear : Theme.hairline))
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One band: a vertical slider that fills from the flat line toward the level.
private struct BandSlider: View {
    let label: String
    let level: Int
    let range: ClosedRange<Int>
    /// The second argument is true while the finger is still down.
    let onChange: (Int, Bool) -> Void
    @State private var dragged: Int?

    private let knob: CGFloat = 16

    var body: some View {
        let shown = dragged ?? level
        VStack(spacing: 8) {
            Text(shown > 0 ? "+\(shown)" : "\(shown)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(shown == 0 ? Theme.tertiaryText : .white)
            GeometryReader { geometry in
                let middle = geometry.size.width / 2
                let y = position(of: shown, in: geometry.size.height)
                let flat = position(of: 0, in: geometry.size.height)
                ZStack {
                    Capsule().fill(.white.opacity(0.13)).frame(width: 4)
                    Capsule().fill(.white).frame(width: 4, height: abs(y - flat)).position(x: middle, y: (y + flat) / 2)
                    Rectangle().fill(.white.opacity(0.3)).frame(width: 12, height: 1).position(x: middle, y: flat)
                    Circle().fill(.white).frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                        .position(x: middle, y: y)
                }
                .contentShape(Rectangle())
                // Ahead of the page's own scrolling, so dragging a band doesn't scroll the page.
                .highPriorityGesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = 1 - (drag.location.y - knob / 2) / (geometry.size.height - knob)
                        let level = range.lowerBound + Int((min(max(fraction, 0), 1) * CGFloat(range.count - 1)).rounded())
                        guard level != dragged else { return }
                        dragged = level
                        onChange(level, true)
                    }
                    .onEnded { _ in
                        if let dragged { onChange(dragged, false) }
                        dragged = nil
                    })
            }
            .frame(height: 150)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("\(label) band")
        .accessibilityValue("\(shown)")
        .accessibilityAdjustableAction { direction in
            let next = level + (direction == .increment ? 1 : -1)
            if range.contains(next) { onChange(next, false) }
        }
    }

    /// Where a level sits on a track of this height: the top of the range at the top.
    private func position(of level: Int, in height: CGFloat) -> CGFloat {
        let fraction = CGFloat(level - range.lowerBound) / CGFloat(max(range.count - 1, 1))
        return (1 - fraction) * (height - knob) + knob / 2
    }
}

// MARK: Audio source

private struct SourceSection: View {
    @Environment(HeadphoneStore.self) private var store

    var body: some View {
        let status = store.status
        let thisPhone = store.thisPhone
        VStack(spacing: 10) {
            SectionLabel(text: "Audio Source")
            ForEach(status.connectedDevices) { device in
                DeviceCard(device: device, detail: device.address == thisPhone?.address ? "This iPhone" : "Connected",
                           isBusy: store.busyDevices.contains(device.address)) {
                    store.play(from: device)
                }
                .contextMenu {
                    Button("Disconnect from Headphones", systemImage: "xmark.circle", role: .destructive) { store.disconnect(device) }
                }
            }
            Text("Tap a device to play from it. Touch and hold to disconnect it from the headphones.")
                .font(.footnote)
                .foregroundStyle(Theme.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            let others = status.devices.filter { !$0.isConnected }
            if !others.isEmpty {
                SectionLabel(text: "Other Paired Devices")
                    .padding(.top, 8)
                ForEach(others) { device in
                    DeviceCard(device: device, detail: "Tap to connect", isBusy: store.busyDevices.contains(device.address)) {
                        store.connect(device)
                    }
                }
            }
        }
    }
}

private struct DeviceCard: View {
    let device: PairedDevice
    let detail: String
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Group {
                    if device.isPlaying {
                        Image(device.wornGlyph).font(.system(size: 22, weight: .medium))
                    } else {
                        Image(systemName: device.symbolName).font(.system(size: 19, weight: .medium))
                    }
                }
                .foregroundStyle(device.isPlaying ? Color.black : .white.opacity(device.isConnected ? 0.85 : 0.45))
                .frame(width: 46, height: 46)
                .background(device.isPlaying ? Color.white : Theme.cardRaised,
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(device.isConnected ? 1 : 0.6))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 8)
                if isBusy {
                    ProgressView()
                } else if device.isPlaying {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                        Text("PLAYING").tracking(1.1)
                    }
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
                }
            }
            .padding(12)
            .background(Theme.card, in: Theme.cardShape)
            .overlay(Theme.cardShape.strokeBorder(device.isPlaying ? .white.opacity(0.4) : Theme.hairline))
            .contentShape(Theme.cardShape)
        }
        .buttonStyle(PressableStyle())
        .disabled(isBusy)
        .accessibilityLabel("\(device.name), \(device.isPlaying ? "playing" : detail)")
    }
}

// MARK: Settings

private struct OptionsSection: View {
    @Environment(HeadphoneStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 10) {
            SectionLabel(text: "Switching")
            VStack(spacing: 14) {
                if store.capabilities?.supportsAutoSwitch == true, let autoSwitch = store.status.autoSwitch {
                    Toggle(isOn: Binding(get: { autoSwitch }, set: { store.setAutoSwitch($0) })) {
                        SettingLabel(title: "Auto-Switch", detail: "Follow whichever device starts playing")
                    }
                    RowDivider()
                }
                HStack {
                    SettingLabel(title: "This iPhone", detail: "For the Control Center toggle")
                    Spacer()
                    Picker("This iPhone", selection: $store.thisPhoneAddress) {
                        Text(automaticLabel).tag(String?.none)
                        ForEach(store.status.devices) { device in
                            Text(device.name).tag(String?.some(device.address))
                        }
                    }
                    .labelsHidden()
                    .tint(Theme.secondaryText)
                }
            }
            .card()
        }
    }

    private var automaticLabel: String {
        let phones = store.status.devices.filter { $0.kind == .phone }
        return phones.count == 1 ? "Automatic (\(phones[0].name))" : "Not Set"
    }
}

private struct SettingLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .medium))
            if let detail {
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

private struct MicrophoneSection: View {
    @Environment(HeadphoneStore.self) private var store

    var body: some View {
        let status = store.status
        if status.sidetone != nil || status.speakToChat != nil || status.micMute != nil {
            VStack(spacing: 10) {
                SectionLabel(text: "Microphone")
                VStack(spacing: 14) {
                    if let sidetone = status.sidetone {
                        Toggle(isOn: Binding(get: { sidetone }, set: { store.setSidetone($0) })) {
                            SettingLabel(title: "Hear Your Voice on Calls", detail: "So you don't talk too loudly")
                        }
                    }
                    if let speakToChat = status.speakToChat {
                        if status.sidetone != nil { RowDivider() }
                        Toggle(isOn: Binding(get: { speakToChat }, set: { store.setSpeakToChat($0) })) {
                            SettingLabel(title: "Speak-to-Chat", detail: "Pause the music when you start talking")
                        }
                        if speakToChat, let detail = status.speakToChatDetail {
                            RowDivider()
                            PickerRow(title: "Sensitivity", selection: Binding(get: { detail.sensitivity }, set: { value in
                                var changed = detail
                                changed.sensitivity = value
                                store.setSpeakToChatDetail(changed)
                            }), options: [(.auto, "Auto"), (.high, "High"), (.low, "Low")])
                            RowDivider()
                            PickerRow(title: "Resume Music After", selection: Binding(get: { detail.timeout }, set: { value in
                                var changed = detail
                                changed.timeout = value
                                store.setSpeakToChatDetail(changed)
                            }), options: [(.short, "Short"), (.standard, "Standard"), (.long, "Long"), (.never, "Don't Resume")])
                        }
                    }
                    if let micMute = status.micMute {
                        if status.sidetone != nil || status.speakToChat != nil { RowDivider() }
                        Toggle(isOn: Binding(get: { micMute.buttonMutes }, set: { on in
                            var changed = micMute
                            changed.buttonMutes = on
                            store.setMicMute(changed)
                        })) {
                            SettingLabel(title: "Mute Mic with Headphone Button", detail: "During calls")
                        }
                        if micMute.buttonMutes {
                            RowDivider()
                            Toggle(isOn: Binding(get: { micMute.playsSound }, set: { on in
                                var changed = micMute
                                changed.playsSound = on
                                store.setMicMute(changed)
                            })) {
                                SettingLabel(title: "Sound When Mic Is Muted")
                            }
                        }
                    }
                }
                .card()
            }
        }
    }
}

private struct PickerRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack {
            SettingLabel(title: title)
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .labelsHidden()
            .tint(Theme.secondaryText)
        }
    }
}
