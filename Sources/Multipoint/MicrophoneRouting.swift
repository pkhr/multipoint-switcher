import AppKit
import CoreAudio
import Darwin

/// Keeps the Mac's default microphone off the headphones.
///
/// While any app records from the headphones' mic, Bluetooth switches them to the hands-free profile: 16 kHz mono in
/// both directions, so everything sounds like a phone call. macOS makes the headphones the default mic whenever they
/// connect; by default this moves it back to another mic.
@MainActor
final class MicrophoneRouter {
    enum Choice: Equatable {
        /// Keep the default mic off the headphones, on the last other mic used (or the built-in one).
        case automatic
        /// Use the headphones' mic, accepting call-quality sound.
        case headphones
        case input(uid: String)
    }

    private static let choiceKey = "macMicrophone"
    private static let headphonesValue = "#headphones" // CoreAudio UIDs never start with "#"
    private static let lastOtherInputKey = "lastNonHeadphonesInputUID"

    /// Normalized Bluetooth address of the headphones.
    var headphonesAddress: String? {
        didSet { if started, headphonesAddress != oldValue { enforce() } }
    }

    var log: ((String) -> Void)?

    private let defaults = UserDefaults.standard
    /// Only the menu bar app changes the default mic; the CLI just reads.
    private var started = false

    var choice: Choice {
        get {
            switch defaults.string(forKey: Self.choiceKey) {
            case nil: return .automatic
            case Self.headphonesValue?: return .headphones
            case let uid?: return .input(uid: uid)
            }
        }
        set {
            switch newValue {
            case .automatic: defaults.removeObject(forKey: Self.choiceKey)
            case .headphones: defaults.set(Self.headphonesValue, forKey: Self.choiceKey)
            case let .input(uid): defaults.set(uid, forKey: Self.choiceKey)
            }
            apply()
        }
    }

    func start() {
        started = true
        AudioDevices.onDefaultChange(.input) { [weak self] in self?.enforce() }
        enforce()
    }

    func isHeadphones(_ input: AudioDevice) -> Bool { input.belongs(toHeadphones: headphonesAddress) }
    var headphonesInput: AudioDevice? { AudioDevices.all(.input).first(where: isHeadphones) }
    var otherInputs: [AudioDevice] { AudioDevices.all(.input).filter { !isHeadphones($0) } }

    var automaticInput: AudioDevice? {
        let candidates = otherInputs
        if let last = defaults.string(forKey: Self.lastOtherInputKey),
           let match = candidates.first(where: { $0.uid == last }) {
            return match
        }
        return candidates.first(where: \.isBuiltIn) ?? candidates.first
    }

    /// The mic to use instead of the headphones'; nil if the user chose the headphones.
    private var preferredInput: AudioDevice? {
        switch choice {
        case .headphones: return nil
        case .automatic: return automaticInput
        case let .input(uid): return otherInputs.first { $0.uid == uid } ?? automaticInput
        }
    }

    /// A choice made in the menu takes effect right away.
    private func apply() {
        switch choice {
        case .headphones:
            if let headphones = headphonesInput { AudioDevices.setDefault(headphones, .input) }
        case .input:
            if let target = preferredInput { AudioDevices.setDefault(target, .input) }
        case .automatic:
            enforce()
        }
    }

    private func enforce() {
        guard let current = AudioDevices.defaultDevice(.input) else { return }
        if isHeadphones(current) {
            guard let target = preferredInput else { return }
            let moved = AudioDevices.setDefault(target, .input)
            log?("default mic was the headphones; moving to \(target.name): \(moved ? "ok" : "failed")")
        } else {
            defaults.set(current.uid, forKey: Self.lastOtherInputKey)
        }
    }

    // MARK: Who's using the headphone mic

    struct MicUser: Equatable {
        let name: String
        /// The app bundle, when the process belongs to one; for bringing it to the front.
        let appURL: URL?
    }

    /// The apps recording from the headphones' mic, or nil if none is (the headphones play at full quality).
    /// Empty when the mic is in use but the apps can't be identified (macOS 13).
    func headphoneMicUsers() -> [MicUser]? {
        guard let input = headphonesInput, input.isRunningSomewhere else { return nil }
        guard #available(macOS 14, *) else { return [] }
        var users: [MicUser] = []
        for process in AudioProcesses.recording(from: input.id) {
            let user = Self.describe(pid: process.pid, bundleID: process.bundleID)
            if !users.contains(where: { $0.name == user.name }) { users.append(user) }
        }
        return users
    }

    /// Helpers (Electron, browsers) run from inside their app's bundle, so name the outermost ".app" in the path.
    private static func describe(pid: pid_t, bundleID: String?) -> MicUser {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            if let range = path.range(of: ".app/") {
                let appURL = URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
                let info = Bundle(url: appURL)?.infoDictionary
                let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
                    ?? appURL.deletingPathExtension().lastPathComponent
                return MicUser(name: name, appURL: appURL)
            }
            return MicUser(name: URL(fileURLWithPath: path).lastPathComponent, appURL: nil)
        }
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return MicUser(name: name, appURL: app.bundleURL)
        }
        return MicUser(name: bundleID ?? "Process \(pid)", appURL: nil)
    }
}

/// CoreAudio's per-process objects (macOS 14+).
@available(macOS 14, *)
enum AudioProcesses {
    struct Process {
        let pid: pid_t
        let bundleID: String?
    }

    static func recording(from device: AudioDeviceID) -> [Process] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioDevices.globalAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            guard uint32(object, kAudioProcessPropertyIsRunningInput) ?? 0 != 0,
                  inputDevices(of: object).contains(device),
                  let rawPID = uint32(object, kAudioProcessPropertyPID) else { return nil }
            let pid = pid_t(bitPattern: rawPID)
            guard pid > 0 else { return nil }
            return Process(pid: pid, bundleID: AudioDevices.string(object, kAudioProcessPropertyBundleID))
        }
    }

    private static func inputDevices(of process: AudioObjectID) -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(process, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioDevices.globalAddress(selector)
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result
    }
}
