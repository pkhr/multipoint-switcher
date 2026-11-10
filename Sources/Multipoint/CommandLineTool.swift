import Foundation
import HeadphoneKit
import IOBluetooth
import MDRKit

/// `Multipoint list | switch <device> | next | connect <device> | disconnect <device> | auto-switch on|off | nc …`
///
/// Each command connects, does its thing and disconnects, the same way the menu bar app does, so the two can be
/// used side by side.
@MainActor
enum CommandLineTool {
    static let commands: Set<String> = ["list", "switch", "next", "connect", "disconnect", "auto-switch", "nc", "mic",
                                        "query", "help", "--help", "-h"]

    static func run(_ rawArguments: [String]) -> Never {
        var arguments = rawArguments
        let debug = arguments.contains("--debug")
        arguments.removeAll { $0 == "--debug" }
        var headphonesQuery: String?
        if let index = arguments.firstIndex(of: "--headphones"), index + 1 < arguments.count {
            headphonesQuery = arguments[index + 1]
            arguments.removeSubrange(index...(index + 1))
        }
        let command = arguments.first ?? "help"
        let operand = arguments.dropFirst().joined(separator: " ")
        if ["help", "--help", "-h"].contains(command) { usage() }

        let remembered = UserDefaults.standard.string(forKey: AppController.headphonesDefaultsKey)
        guard let headphones = headphonesQuery.map(HeadphoneDirectory.find)
                ?? HeadphoneDirectory.preferred(rememberedAddress: remembered) else {
            fail("No paired Sony headphones found.")
        }
        let name = headphones.name ?? "Headphones"
        guard headphones.isConnected() else {
            fail("\(name) isn't connected to this Mac. Connect it in Bluetooth settings first.")
        }

        let controller = HeadphoneController { BluetoothLink(device: headphones) }
        if debug { controller.log = { printError("  \($0)") } }
        controller.onNotice = { printError($0) }
        // `hold` keeps the channel open until the process exits; read everything before acting.
        controller.hold()
        controller.sync { failure in
            if let failure { fail(failure) }
            perform(command, operand, controller: controller, name: name,
                    headphonesAddress: headphones.normalizedAddress)
        }
        Task {
            try? await Task.sleep(for: .seconds(25))
            fail("Timed out talking to \(name).")
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func perform(_ command: String, _ operand: String, controller: HeadphoneController, name: String,
                                headphonesAddress: String) {
        let status = controller.status
        switch command {
        case "list":
            printDevices(controller, name: name)
            exit(0)

        case "switch", "next":
            let target: PairedDevice
            if command == "next" {
                guard let next = status.nextDevice else { fail("Only one device is connected.") }
                target = next
            } else {
                target = findDevice(operand, in: status)
                guard target.isConnected else { fail("\(target.name) is paired but not connected. Try: connect \"\(target.name)\"") }
            }
            if target.isPlaying {
                print("Already playing from \(target.name).")
                exit(0)
            }
            let router = AudioRouter()
            router.headphonesAddress = headphonesAddress
            let targetIsMac = target.normalizedAddress == HeadphoneDirectory.hostAddress
            if targetIsMac { router.routeToHeadphones() }
            controller.switchPlayback(to: target) { failure in
                if failure != nil { exit(1) } // the reason was already printed as a notice
                print("Now playing from \(target.name).")
                // Same rule as the menu bar app: with auto-switch off the headphones won't return to the Mac on
                // their own, so Mac audio would be lost on them.
                if !targetIsMac, controller.status.autoSwitch == false, let moved = router.moveOffHeadphones() {
                    print("Mac audio moved to \(moved.name).")
                }
                exit(0)
            }

        case "connect", "disconnect":
            let target = findDevice(operand, in: status)
            let done: (String?) -> Void = { failure in
                if failure != nil { exit(1) }
                printDevices(controller, name: name)
                exit(0)
            }
            if command == "connect" { controller.connect(target, completion: done) } else { controller.disconnect(target, completion: done) }

        case "nc":
            guard var noise = status.noiseControl else { fail("These headphones don't offer noise control.") }
            let words = operand.lowercased().split(separator: " ").map(String.init)
            switch words.first {
            case nil:
                print(describe(noise))
                exit(0)
            case "on"?, "nc"?, "cancel"?, "cancelling"?:
                guard noise.variant.hasNoiseCancelling else { fail("These headphones have ambient sound only.") }
                noise.mode = .noiseCancelling
            case "ambient"?:
                noise.mode = .ambient
                if words.count > 1 {
                    guard let level = UInt8(words[1]), NoiseControl.ambientLevels.contains(level) else {
                        fail("The ambient level goes from \(NoiseControl.ambientLevels.lowerBound) to \(NoiseControl.ambientLevels.upperBound).")
                    }
                    noise.ambientLevel = level
                    if noise.adjustsAutomatically == true { noise.adjustsAutomatically = false }
                }
            case "off"?:
                noise.mode = .off
            default:
                fail("Usage: nc [on|ambient [level]|off]")
            }
            controller.setNoiseControl(noise)
            // Read it back from the headphones rather than trusting what was just sent.
            controller.sync(.noiseControl) { failure in
                if let failure { fail(failure) }
                print(controller.status.noiseControl.map(describe) ?? "Noise control: unknown")
                exit(controller.status.noiseControl?.mode == noise.mode ? 0 : 1)
            }

        case "mic":
            printMicrophone(status, headphonesAddress: headphonesAddress)
            exit(0)

        case "query":
            // e.g. `query "t1 F6 0C, t2 F6 0B"`: raw requests, one reply line each. Meant for get-style commands.
            var requests: [(table: UInt8, payload: [UInt8], text: String)] = []
            for part in operand.split(separator: ",") {
                let words = part.split(separator: " ").map { $0.lowercased() }
                let table: UInt8? = words.first == "t1" ? MDRDataType.table1 : words.first == "t2" ? MDRDataType.table2 : nil
                let bytes = words.dropFirst().compactMap { UInt8($0, radix: 16) }
                guard let table, !bytes.isEmpty, bytes.count == words.count - 1 else {
                    fail("Usage: query \"t1|t2 <hex bytes>[, …]\"")
                }
                requests.append((table, bytes, part.trimmingCharacters(in: .whitespaces)))
            }
            guard !requests.isEmpty else { fail("Usage: query \"t1|t2 <hex bytes>[, …]\"") }
            func next(_ index: Int) {
                guard index < requests.count else { exit(0) }
                let request = requests[index]
                controller.query(table: request.table, request.payload) { reply in
                    print("\(request.text) -> \(reply.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") } ?? "(no reply)")")
                    next(index + 1)
                }
            }
            next(0)

        case "auto-switch":
            guard controller.capabilities?.supportsAutoSwitch == true else { fail("These headphones don't offer the auto-switch setting.") }
            switch operand.lowercased() {
            case "on": controller.setAutoSwitch(true)
            case "off": controller.setAutoSwitch(false)
            case "": break
            default: fail("Usage: auto-switch on|off")
            }
            controller.sync(.devices) { failure in
                if let failure { fail(failure) }
                print("Auto-switch is \(controller.status.autoSwitch == true ? "on" : "off").")
                exit(0)
            }

        default:
            usage()
        }
    }

    private static func findDevice(_ query: String, in status: HeadphoneStatus) -> PairedDevice {
        guard !query.isEmpty else { fail("Name the device, e.g.: switch iPhone") }
        let normalized = normalizeAddress(query)
        let matches = status.devices.filter {
            (!normalized.isEmpty && $0.normalizedAddress == normalized) || $0.name.localizedCaseInsensitiveContains(query)
        }
        guard let first = matches.first else {
            fail("No paired device matches \"\(query)\". Run `list` to see them.")
        }
        if matches.count > 1, !matches.contains(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            fail("\"\(query)\" matches several devices: \(matches.map(\.name).joined(separator: ", "))")
        }
        return matches.first { $0.name.caseInsensitiveCompare(query) == .orderedSame } ?? first
    }

    private static func printDevices(_ controller: HeadphoneController, name: String) {
        let host = HeadphoneDirectory.hostAddress
        let status = controller.status
        print("\(name)")
        if status.devices.isEmpty { print("  (no paired devices reported)") }
        for device in status.devices {
            let marker = device.isPlaying ? "▶" : device.isConnected ? "●" : "○"
            let state = device.isPlaying ? "playing" : device.isConnected ? "connected" : "paired"
            let label = device.normalizedAddress == host ? "\(device.name) (this Mac)" : device.name
            print("  \(marker) \(label.padding(toLength: max(label.count, 34), withPad: " ", startingAt: 0)) \(device.address)  \(state)")
        }
        if let autoSwitch = status.autoSwitch {
            print("Auto-switch when another device plays: \(autoSwitch ? "on" : "off")")
        }
    }

    private static func describe(_ noise: NoiseControl) -> String {
        switch noise.mode {
        case .noiseCancelling: return "Noise control: noise cancelling"
        case .off: return "Noise control: off"
        case .ambient:
            let level = noise.adjustsAutomatically == true ? "level set automatically" : "level \(noise.ambientLevel)"
            return "Noise control: ambient sound (\(level)\(noise.focusOnVoice ? ", focus on voice" : ""))"
        }
    }

    private static func printMicrophone(_ status: HeadphoneStatus, headphonesAddress: String) {
        let router = MicrophoneRouter()
        router.headphonesAddress = headphonesAddress
        let mode: String
        switch router.choice {
        case .automatic: mode = "kept off the headphones"
        case .headphones: mode = "headphones allowed"
        case let .input(uid): mode = "pinned to \(router.otherInputs.first { $0.uid == uid }?.name ?? uid)"
        }
        print("Mac microphone: \(AudioDevices.defaultDevice(.input)?.name ?? "none") (\(mode))")
        switch router.headphoneMicUsers() {
        case nil: print("Headphones play at full quality: no app is using their mic.")
        case let users?:
            let who = users.isEmpty ? "an app" : users.map(\.name).joined(separator: ", ")
            print("Call-quality sound: \(who) using the headphone mic.")
        }
        func onOff(_ value: Bool?) -> String { value.map { $0 ? "on" : "off" } ?? "not available" }
        print("Hear your voice on calls (sidetone): \(onOff(status.sidetone))")
        var speakToChat = "Speak-to-Chat: \(onOff(status.speakToChat))"
        if let detail = status.speakToChatDetail {
            speakToChat += " (sensitivity \(detail.sensitivity), resume after: \(detail.timeout))"
        }
        print(speakToChat)
        if let mute = status.micMute {
            print("Mute mic with headphone button: \(onOff(mute.buttonMutes)), sound when muted: \(onOff(mute.playsSound))")
        } else {
            print("Mute mic with headphone button: not available")
        }
    }

    private static func usage() -> Never {
        print("""
        Usage: Multipoint [command] [--headphones <name|address>] [--debug]

        With no command, runs as a menu bar app.

          list                      Show devices paired with the headphones and which one is playing
          switch <name|address>     Make a connected device the audio source
          next                      Switch to the other connected device
          connect <name|address>    Ask the headphones to connect to a paired device
          disconnect <name>         Ask the headphones to drop a device
          auto-switch [on|off]      Whether the headphones may switch sources on their own
          nc [on|ambient [1-20]|off]  Noise cancelling, ambient sound (optionally at a level), or neither
          mic                       Show the Mac's microphone, who uses the headphone mic, and mic settings
          query "t1|t2 <hex>, …"    Send raw protocol requests and print the replies (for exploring)
        """)
        exit(0)
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func fail(_ message: String) -> Never {
        printError(message)
        exit(1)
    }
}
