import Foundation
import HeadphoneKit
import MDRKit

/// What the app last learned from the headphones, kept where the Control Center controls can read it.
///
/// Controls are drawn by the widget extension, which can't talk to the headphones itself. The app writes here every
/// time something changes, and the controls show what they find.
enum SharedState {
    static let appGroup = "group.dev.pkhri.Multipoint"

    private static let snapshotKey = "snapshot"
    private static let nameKey = "headphonesName"
    private static let thisPhoneKey = "thisPhoneAddress"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static var snapshot: HeadphoneSnapshot? {
        get {
            defaults.data(forKey: snapshotKey).flatMap { try? JSONDecoder().decode(HeadphoneSnapshot.self, from: $0) }
        }
        set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: snapshotKey)
        }
    }

    static var status: HeadphoneStatus { snapshot?.status ?? HeadphoneStatus() }

    /// The equalizer's presets, as the headphones listed them.
    static var equalizerPresets: [EqualizerPreset] { snapshot?.capabilities?.equalizer?.presets ?? [] }

    /// The app version that read the remembered capabilities.
    static var capabilitiesVersion: String? {
        get { defaults.string(forKey: "capabilitiesVersion") }
        set { defaults.set(newValue, forKey: "capabilitiesVersion") }
    }

    static var headphonesName: String? {
        get { defaults.string(forKey: nameKey) }
        set { defaults.set(newValue, forKey: nameKey) }
    }

    /// Which entry of the headphones' device list is this iPhone. iOS doesn't tell apps its Bluetooth address, so
    /// it's the list's only phone unless the user picked another in the app.
    static var thisPhoneAddress: String? {
        get { defaults.string(forKey: thisPhoneKey) }
        set { defaults.set(newValue, forKey: thisPhoneKey) }
    }

    static func thisPhone(in status: HeadphoneStatus) -> PairedDevice? {
        if let chosen = thisPhoneAddress, let device = status.device(matching: chosen) { return device }
        let phones = status.devices.filter { $0.kind == .phone }
        return phones.count == 1 ? phones[0] : nil
    }
}

/// A failure worth showing as is, e.g. "Can't switch during a call".
struct HeadphoneError: LocalizedError, CustomLocalizedStringResourceConvertible {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// What the intents below ask of the app. The app sets `handler` as it launches; in the widget extension it stays nil.
@MainActor
protocol HeadphoneCommandHandling: AnyObject {
    func setNoiseMode(_ mode: NoiseControlMode) async throws
    /// Moves to the next of Noise Cancelling → Ambient Sound → Off and returns it.
    func cycleNoiseMode() async throws -> NoiseControlMode
    /// Switches to the connected device after the one that's playing and returns its name.
    func switchToNextDevice() async throws -> String
    func switchPlayback(toAddress address: String) async throws
    func setSwitch(_ setting: HeadphoneSwitch, on: Bool) async throws
    /// Moves a stepped setting on by one and returns what it is now, in words.
    func step(_ step: HeadphoneStep) async throws -> String
    func setDevice(address: String, connected: Bool) async throws
    /// Selects an equalizer preset and returns its name.
    func setEqualizerPreset(id: UInt8) async throws -> String
    /// Moves to the next equalizer preset and returns its name.
    func cycleEqualizerPreset() async throws -> String
}

@MainActor
enum HeadphoneCommands {
    static var handler: HeadphoneCommandHandling?

    static func current() throws -> HeadphoneCommandHandling {
        guard let handler else { throw HeadphoneError("Open Multipoint once so it can reach your headphones.") }
        return handler
    }
}
