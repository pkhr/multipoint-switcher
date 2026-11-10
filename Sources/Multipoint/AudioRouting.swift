import CoreAudio
import Foundation
import MDRKit

enum AudioDirection {
    case output, input

    var scope: AudioObjectPropertyScope {
        self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
    }

    var defaultDeviceSelector: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }
}

struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    /// Bluetooth devices' UIDs are "<address>:output" / "<address>:input".
    func belongs(toHeadphones address: String?) -> Bool {
        guard isBluetooth, let address else { return false }
        return normalizeAddress(String(uid.prefix { $0 != ":" })) == address
    }

    /// Whether any process is currently doing I/O on the device.
    var isRunningSomewhere: Bool {
        var address = AudioDevices.globalAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr && running != 0
    }
}

/// Thin wrapper over CoreAudio's device list and the system default input and output.
enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func all(_ direction: AudioDirection) -> [AudioDevice] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { device($0, direction) }
    }

    static func defaultDevice(_ direction: AudioDirection) -> AudioDevice? {
        var address = globalAddress(direction.defaultDeviceSelector)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr else { return nil }
        return device(id, direction)
    }

    @discardableResult
    static func setDefault(_ device: AudioDevice, _ direction: AudioDirection) -> Bool {
        var address = globalAddress(direction.defaultDeviceSelector)
        var id = device.id
        return AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    static func onDefaultChange(_ direction: AudioDirection, _ handler: @escaping @MainActor () -> Void) {
        listen(system, direction.defaultDeviceSelector, handler)
    }

    /// A device appeared or went away.
    static func onDevicesChange(_ handler: @escaping @MainActor () -> Void) {
        listen(system, kAudioHardwarePropertyDevices, handler)
    }

    /// Calls `handler` on the main thread whenever the property changes. Keep the returned block to stop listening.
    @discardableResult
    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ handler: @escaping @MainActor () -> Void) -> AudioObjectPropertyListenerBlock {
        var address = globalAddress(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { handler() } }
        AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
        return block
    }

    static func stopListening(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              _ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = globalAddress(selector)
        AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }

    private static func device(_ id: AudioDeviceID, _ direction: AudioDirection) -> AudioDevice? {
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: direction.scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr, size > 0,
              let uid = string(id, kAudioDevicePropertyDeviceUID),
              let name = string(id, kAudioObjectPropertyName) else { return nil }
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = globalAddress(kAudioDevicePropertyTransportType)
        AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
        return AudioDevice(id: id, uid: uid, name: name, transport: transport)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

/// Keeps the Mac's sound audible when the headphones play from another device.
///
/// The headphones stay connected to the Mac while another device is their source, so macOS keeps sending audio to
/// them and it's silently dropped. While auto-switch is off (the headphones won't come back on their own), Mac audio
/// is moved to another output, and moved back once the Mac is the source again.
@MainActor
final class AudioRouter {
    enum Choice: Equatable {
        case automatic
        case stayOnHeadphones
        case output(uid: String)
    }

    private static let choiceKey = "macAudioWhenSwitchedAway"
    private static let stayValue = "stay"
    private static let lastOtherOutputKey = "lastNonHeadphonesOutputUID"
    private static let movedToKey = "macAudioMovedToUID"

    /// Normalized Bluetooth address of the headphones; their CoreAudio UID is "<address>:output".
    var headphonesAddress: String? {
        didSet { if observing { watchHeadphonesOutput() } }
    }

    /// The Mac started or stopped sending sound to the headphones, or the default output changed. These are the
    /// moments worth checking whether the headphones are actually listening to the Mac.
    var onOutputActivity: (() -> Void)?

    /// Mac audio is currently on another output because the headphones are playing from another device.
    var isDiverted: Bool { movedTo != nil }

    /// Some app is sending sound to the headphones right now.
    var headphonesOutputIsRunning: Bool { headphonesOutput?.isRunningSomewhere == true }

    private var observing = false
    private var watched: (id: AudioDeviceID, block: AudioObjectPropertyListenerBlock)?

    private let defaults = UserDefaults.standard
    private var shouldBeOffHeadphones: Bool?

    /// The output we moved Mac audio to, persisted so a restart can still bring it back.
    private var movedTo: String? {
        get { defaults.string(forKey: Self.movedToKey) }
        set { defaults.set(newValue, forKey: Self.movedToKey) }
    }

    var choice: Choice {
        get {
            switch defaults.string(forKey: Self.choiceKey) {
            case nil: return .automatic
            case Self.stayValue?: return .stayOnHeadphones
            case let uid?: return .output(uid: uid)
            }
        }
        set {
            switch newValue {
            case .automatic: defaults.removeObject(forKey: Self.choiceKey)
            case .stayOnHeadphones: defaults.set(Self.stayValue, forKey: Self.choiceKey)
            case let .output(uid): defaults.set(uid, forKey: Self.choiceKey)
            }
        }
    }

    /// Remembers the last output the user picked that isn't the headphones, for `.automatic`, and reports activity.
    func startObservingOutputChanges() {
        observing = true
        AudioDevices.onDefaultChange(.output) { [weak self] in
            self?.rememberCurrentOutput()
            self?.onOutputActivity?()
        }
        AudioDevices.onDevicesChange { [weak self] in self?.watchHeadphonesOutput() }
        rememberCurrentOutput()
        watchHeadphonesOutput()
    }

    /// The headphones' audio device is a new object each time they connect, so follow it around.
    private func watchHeadphonesOutput() {
        let current = headphonesOutput?.id
        guard current != watched?.id else { return }
        if let watched {
            AudioDevices.stopListening(watched.id, kAudioDevicePropertyDeviceIsRunningSomewhere, watched.block)
        }
        watched = current.map { id in
            (id, AudioDevices.listen(id, kAudioDevicePropertyDeviceIsRunningSomewhere) { [weak self] in
                self?.onOutputActivity?()
            })
        }
    }

    func isHeadphones(_ output: AudioDevice) -> Bool { output.belongs(toHeadphones: headphonesAddress) }

    var headphonesOutput: AudioDevice? { AudioDevices.all(.output).first(where: isHeadphones) }
    var otherOutputs: [AudioDevice] { AudioDevices.all(.output).filter { !isHeadphones($0) } }

    var automaticOutput: AudioDevice? {
        let candidates = otherOutputs
        if let last = defaults.string(forKey: Self.lastOtherOutputKey),
           let match = candidates.first(where: { $0.uid == last }) {
            return match
        }
        return candidates.first(where: \.isBuiltIn) ?? candidates.first
    }

    /// Where Mac audio goes when switched away; nil if the user wants it left on the headphones.
    var fallbackOutput: AudioDevice? {
        switch choice {
        case .stayOnHeadphones: return nil
        case .automatic: return automaticOutput
        case let .output(uid): return otherOutputs.first { $0.uid == uid } ?? automaticOutput
        }
    }

    /// Feed the current situation; acts only when it changes, so a manual output choice isn't fought every poll.
    func update(macShouldLeaveHeadphones: Bool) {
        guard macShouldLeaveHeadphones != shouldBeOffHeadphones else { return }
        shouldBeOffHeadphones = macShouldLeaveHeadphones
        if macShouldLeaveHeadphones { moveOffHeadphones() } else { restoreIfMoved() }
    }

    /// Forget the last observed situation (e.g. new connection) so the next `update` acts.
    func resetTracking() { shouldBeOffHeadphones = nil }

    @discardableResult
    func moveOffHeadphones() -> AudioDevice? {
        guard let current = AudioDevices.defaultDevice(.output), isHeadphones(current),
              let target = fallbackOutput, AudioDevices.setDefault(target, .output) else { return nil }
        movedTo = target.uid
        return target
    }

    /// The user explicitly made the Mac the source: its audio belongs on the headphones.
    func routeToHeadphones() {
        movedTo = nil
        guard let headphones = headphonesOutput, AudioDevices.defaultDevice(.output)?.id != headphones.id else { return }
        AudioDevices.setDefault(headphones, .output)
    }

    private func restoreIfMoved() {
        guard let movedTo else { return }
        self.movedTo = nil
        // If the user picked another output in the meantime, leave their choice alone.
        guard AudioDevices.defaultDevice(.output)?.uid == movedTo, let headphones = headphonesOutput else { return }
        AudioDevices.setDefault(headphones, .output)
    }

    private func rememberCurrentOutput() {
        guard let current = AudioDevices.defaultDevice(.output), !isHeadphones(current) else { return }
        defaults.set(current.uid, forKey: Self.lastOtherOutputKey)
    }
}
