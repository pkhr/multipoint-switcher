import ExternalAccessory
import Foundation
import HeadphoneKit
import MDRKit
import Observation
import WidgetKit

/// The app's view of the headphones: what the screen shows, and what the Control Center controls and Shortcuts
/// actions call into. Connects only while the app is on screen or a command is running.
@MainActor
@Observable
final class HeadphoneStore: HeadphoneCommandHandling {
    static let shared = HeadphoneStore()

    private(set) var status = HeadphoneStatus()
    private(set) var capabilities: HeadphoneCapabilities?
    private(set) var link = HeadphoneController.Link.idle
    private(set) var busyDevices: Set<String> = []
    private(set) var headphonesName: String?
    /// The headphones are connected to this iPhone and offering their control channel.
    private(set) var isReachable = false
    var notice: String?
    var thisPhoneAddress: String? = SharedState.thisPhoneAddress {
        didSet {
            SharedState.thisPhoneAddress = thisPhoneAddress
            ControlCenter.shared.reloadAllControls()
        }
    }

    @ObservationIgnored private var controller: HeadphoneController!
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Stands in for real headphones in the Simulator, which has no Bluetooth.
    @ObservationIgnored private var simulated: SimulatedHeadphones.Memory?

    private init() {
        #if targetEnvironment(simulator)
        simulated = SimulatedHeadphones.Memory()
        if ProcessInfo.processInfo.environment["SIMULATED_NOISE"] == "ambient" {
            simulated?.noise = [0x01, 0x01, 0x01, 0x00, 0x0C, 0x00, 0x00]
        }
        #endif
        headphonesName = SharedState.headphonesName
        controller = HeadphoneController(snapshot: SharedState.snapshot) { [weak self] in self?.makeTransport() }
        controller.onChange = { [weak self] in self?.controllerChanged() }
        controller.onNotice = { [weak self] in self?.notice = $0 }
        status = controller.status
        capabilities = controller.capabilities

        let manager = EAAccessoryManager.shared()
        manager.registerForLocalNotifications()
        for name in [Notification.Name.EAAccessoryDidConnect, .EAAccessoryDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.accessoriesChanged() }
            })
        }
        accessoriesChanged()
    }

    private func makeTransport() -> HeadphoneTransport? {
        if let simulated { return SimulatedHeadphones(memory: simulated) }
        return AccessoryTransport.connectedHeadphones.map(AccessoryTransport.init)
    }

    private func accessoriesChanged() {
        let wasReachable = isReachable
        if simulated != nil {
            isReachable = true
            setName("Simulated Headphones")
        } else if let accessory = AccessoryTransport.connectedHeadphones {
            isReachable = true
            setName(accessory.name)
        } else {
            isReachable = false
        }
        guard isReachable != wasReachable else { return }
        if isReachable {
            if isVisible { controller.sync() }
        } else {
            controller.reset(keepingStatus: true)
        }
    }

    private func setName(_ name: String) {
        if let known = headphonesName, known != name {
            controller.reset() // different headphones: what was remembered doesn't apply
        }
        headphonesName = name
        SharedState.headphonesName = name
    }

    private func controllerChanged() {
        let before = status
        status = controller.status
        capabilities = controller.capabilities
        link = controller.link
        busyDevices = controller.busyDevices
        guard status != before else { return }
        SharedState.snapshot = controller.snapshot
        ControlCenter.shared.reloadAllControls()
    }

    // MARK: On screen

    /// While the app is in front, stay connected and keep the device list current.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            accessoriesChanged()
            controller.hold()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isReachable else { return }
                    self.controller.sync(.devices)
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
            controller.release()
        }
    }

    func retry() {
        accessoriesChanged()
        controller.sync()
    }

    /// For headphones that are connected for audio but haven't offered the control channel to apps yet.
    func showAccessoryPicker() {
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { [weak self] _ in
            Task { @MainActor in self?.accessoriesChanged() }
        }
    }

    var thisPhone: PairedDevice? { SharedState.thisPhone(in: status) }

    func play(from device: PairedDevice) {
        guard !device.isPlaying else { return }
        controller.switchPlayback(to: device)
    }

    /// Moves the audio to the other connected device, going by the list on screen.
    func switchToOtherDevice() {
        guard let target = status.nextDevice else { return }
        controller.switchPlayback(to: target)
    }

    func connect(_ device: PairedDevice) { controller.connect(device) }
    func disconnect(_ device: PairedDevice) { controller.disconnect(device) }
    func setNoiseControl(_ value: NoiseControl, adjusting: Bool = false) { controller.setNoiseControl(value, adjusting: adjusting) }
    func setAutoSwitch(_ on: Bool) { controller.setAutoSwitch(on) }
    func setSidetone(_ on: Bool) { controller.setSidetone(on) }
    func setSpeakToChat(_ on: Bool) { controller.setSpeakToChat(on) }
    func setSpeakToChatDetail(_ detail: SpeakToChatDetail) { controller.setSpeakToChatDetail(detail) }
    func setMicMute(_ settings: MicMuteSettings) { controller.setMicMute(settings) }

    // MARK: Commands from controls, Shortcuts and Siri

    func setNoiseMode(_ mode: NoiseControlMode) async throws {
        // Read first: the level and options are sent along with the mode, and they may have changed elsewhere.
        try await sync(.noiseControl)
        guard var noise = controller.status.noiseControl else { throw HeadphoneError("These headphones don't offer noise control.") }
        guard noise.availableModes.contains(mode) else { throw HeadphoneError("These headphones don't have \(mode.title.lowercased()).") }
        noise.mode = mode
        controller.setNoiseControl(noise)
        try await sync(.noiseControl) // queued behind the write, so this is the headphones' answer
        guard controller.status.noiseControl?.mode == mode else { throw HeadphoneError("The headphones didn't change mode.") }
    }

    func cycleNoiseMode() async throws -> NoiseControlMode {
        try await sync(.noiseControl)
        guard let noise = controller.status.noiseControl else { throw HeadphoneError("These headphones don't offer noise control.") }
        let modes = noise.availableModes
        let next = modes[((modes.firstIndex(of: noise.mode) ?? -1) + 1) % modes.count]
        try await setNoiseMode(next)
        return next
    }

    func switchToNextDevice() async throws -> String {
        try await sync(.devices)
        guard let target = controller.status.nextDevice else { throw HeadphoneError("Only one device is connected to the headphones.") }
        try await switchPlayback(to: target)
        return target.name
    }

    func switchPlayback(toAddress address: String) async throws {
        try await sync(.devices)
        guard let target = controller.status.device(matching: address) else { throw HeadphoneError("The headphones no longer know that device.") }
        guard target.isConnected else { throw HeadphoneError("\(target.name) isn't connected to the headphones.") }
        if !target.isPlaying { try await switchPlayback(to: target) }
    }

    func setSwitch(_ setting: HeadphoneSwitch, on: Bool) async throws {
        let unavailable = HeadphoneError("These headphones don't have that setting.")
        switch setting {
        case .autoAmbient, .focusOnVoice:
            try await sync(.noiseControl)
            guard var noise = controller.status.noiseControl else { throw unavailable }
            if setting == .autoAmbient {
                guard noise.adjustsAutomatically != nil else { throw unavailable }
                noise.adjustsAutomatically = on
            } else {
                noise.focusOnVoice = on
            }
            controller.setNoiseControl(noise)
            try await sync(.noiseControl)
        case .autoSwitch:
            try await sync(.devices)
            guard controller.status.autoSwitch != nil else { throw unavailable }
            controller.setAutoSwitch(on)
            try await sync(.devices)
        case .sidetone, .speakToChat, .micMuteButton, .micMuteSound:
            try await sync(.settings)
            let status = controller.status
            switch setting {
            case .sidetone:
                guard status.sidetone != nil else { throw unavailable }
                controller.setSidetone(on)
            case .speakToChat:
                guard status.speakToChat != nil else { throw unavailable }
                controller.setSpeakToChat(on)
            default:
                guard var mute = status.micMute else { throw unavailable }
                if setting == .micMuteButton { mute.buttonMutes = on } else { mute.playsSound = on }
                controller.setMicMute(mute)
            }
            try await sync(.settings) // queued behind the write, so this is the headphones' answer
        }
        guard setting.value(in: controller.status) == on else { throw HeadphoneError("The headphones didn't take the change.") }
    }

    func step(_ step: HeadphoneStep) async throws -> String {
        switch step {
        case .ambientMore, .ambientLess:
            try await sync(.noiseControl)
            guard var noise = controller.status.noiseControl else { throw HeadphoneError("These headphones don't offer noise control.") }
            // Stepping the level means ambient sound, at a level you chose rather than one the headphones pick.
            let levels = NoiseControl.ambientLevels
            let stepped = Int(noise.ambientLevel) + (step == .ambientMore ? 2 : -2)
            noise.ambientLevel = UInt8(min(max(stepped, Int(levels.lowerBound)), Int(levels.upperBound)))
            noise.mode = .ambient
            if noise.adjustsAutomatically == true { noise.adjustsAutomatically = false }
            controller.setNoiseControl(noise)
            try await sync(.noiseControl)
            return "Level \(controller.status.noiseControl?.ambientLevel ?? noise.ambientLevel)"
        case .chatSensitivity, .chatResume:
            try await sync(.settings)
            guard var detail = controller.status.speakToChatDetail else { throw HeadphoneError("These headphones don't have Speak-to-Chat.") }
            if step == .chatSensitivity {
                let all = SpeakToChatSensitivity.allCases
                detail.sensitivity = all[(all.firstIndex(of: detail.sensitivity)! + 1) % all.count]
            } else {
                let all = SpeakToChatTimeout.allCases
                detail.timeout = all[(all.firstIndex(of: detail.timeout)! + 1) % all.count]
            }
            controller.setSpeakToChatDetail(detail)
            try await sync(.settings)
            let now = controller.status.speakToChatDetail ?? detail
            return step == .chatSensitivity ? now.sensitivity.title : now.timeout.title
        }
    }

    func setDevice(address: String, connected: Bool) async throws {
        try await sync(.devices)
        guard let target = controller.status.device(matching: address) else { throw HeadphoneError("The headphones no longer know that device.") }
        guard target.isConnected != connected else { return }
        let failure: String? = await withCheckedContinuation { continuation in
            if connected {
                controller.connect(target) { continuation.resume(returning: $0) }
            } else {
                controller.disconnect(target) { continuation.resume(returning: $0) }
            }
        }
        if let failure { throw HeadphoneError(failure) }
    }

    private func switchPlayback(to target: PairedDevice) async throws {
        let failure: String? = await withCheckedContinuation { continuation in
            controller.switchPlayback(to: target) { continuation.resume(returning: $0) }
        }
        if let failure { throw HeadphoneError(failure) }
    }

    private func sync(_ scope: HeadphoneSession.Scope) async throws {
        accessoriesChanged()
        guard isReachable else { throw HeadphoneError("The headphones aren't connected to this iPhone.") }
        let failure: String? = await withCheckedContinuation { continuation in
            controller.sync(scope) { continuation.resume(returning: $0) }
        }
        if let failure { throw HeadphoneError(failure) }
    }
}
