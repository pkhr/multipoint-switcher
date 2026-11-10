import XCTest
import HeadphoneKit
import MDRKit

@MainActor
final class HeadphoneControllerTests: XCTestCase {
    /// One entry per connection made; they share `memory`, like reconnecting to the same headphones.
    private var headphones: [SimulatedHeadphones] = []
    private let memory = SimulatedHeadphones.Memory()
    private var failOpen: String?
    private var unreachable = false
    private var notices: [String] = []

    private func makeController(snapshot: HeadphoneSnapshot? = nil) -> HeadphoneController {
        let controller = HeadphoneController(snapshot: snapshot) { [unowned self] in
            if self.unreachable { return nil }
            let next = SimulatedHeadphones(memory: self.memory)
            next.failOpen = self.failOpen
            self.headphones.append(next)
            return next
        }
        controller.linger = .milliseconds(40)
        controller.onNotice = { [unowned self] in self.notices.append($0) }
        return controller
    }

    private func wait(_ what: String, _ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    private func sync(_ controller: HeadphoneController, _ scope: HeadphoneSession.Scope = .all) async -> String? {
        await withCheckedContinuation { continuation in
            controller.sync(scope) { continuation.resume(returning: $0) }
        }
    }

    func testSyncReadsEverythingThenLetsGoOfTheChannel() async {
        let controller = makeController()
        XCTAssertEqual(controller.link, .idle)
        let failure = await sync(controller)
        XCTAssertNil(failure)
        XCTAssertEqual(controller.link, .live)
        XCTAssertEqual(controller.status.devices.map(\.name), ["MacBook", "iPhone", "iPad"])
        XCTAssertEqual(controller.status.playingDevice?.name, "MacBook")
        XCTAssertEqual(controller.status.nextDevice?.name, "iPhone")
        XCTAssertEqual(controller.status.autoSwitch, true)
        XCTAssertEqual(controller.status.noiseControl?.mode, .noiseCancelling)
        XCTAssertEqual(controller.status.noiseControl?.ambientLevel, 20)
        XCTAssertEqual(controller.status.sidetone, false)
        XCTAssertEqual(controller.status.speakToChat, true)
        XCTAssertEqual(controller.status.micMute, MicMuteSettings(buttonMutes: true, playsSound: false))
        XCTAssertEqual(controller.capabilities?.noiseControlVariant, .adaptive)
        XCTAssertNotNil(controller.lastSync)

        await wait("channel released") { controller.link == .idle }
        XCTAssertEqual(headphones.count, 1)
        XCTAssertEqual(headphones[0].closeCount, 1)
        XCTAssertFalse(headphones[0].isOpen)
    }

    func testLaterConnectionsSkipTheCapabilityQueries() async {
        let controller = makeController()
        _ = await sync(controller)
        await wait("channel released") { controller.link == .idle }
        _ = await sync(controller, .devices)
        XCTAssertEqual(headphones.count, 2)
        // Protocol info always; nothing else from the handshake.
        XCTAssertEqual(headphones[1].received(0x00, table: MDRDataType.table1).count, 1)
        XCTAssertTrue(headphones[1].received(0x06, table: MDRDataType.table1).isEmpty)
        XCTAssertTrue(headphones[1].received(0x06, table: MDRDataType.table2).isEmpty)
        XCTAssertTrue(headphones[1].received(0xD0, table: MDRDataType.table1).isEmpty)
        XCTAssertEqual(headphones[1].received.count, 3) // protocol info, device list, auto-switch
    }

    func testSnapshotCarriesOverToANewController() async {
        let first = makeController()
        _ = await sync(first)
        let data = try! JSONEncoder().encode(first.snapshot)
        let restored = try! JSONDecoder().decode(HeadphoneSnapshot.self, from: data)
        XCTAssertEqual(restored, first.snapshot)

        let second = makeController(snapshot: restored)
        XCTAssertEqual(second.status.playingDevice?.name, "MacBook")
        XCTAssertEqual(second.link, .idle)
        XCTAssertEqual(headphones.count, 1) // restoring didn't connect
    }

    func testHoldKeepsTheChannelUntilReleased() async {
        let controller = makeController()
        controller.hold()
        await wait("live") { controller.link == .live }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(controller.link, .live)
        XCTAssertTrue(headphones[0].isOpen)
        controller.release()
        await wait("released") { controller.link == .idle }
        XCTAssertFalse(headphones[0].isOpen)
    }

    func testNoiseModeShowsAtOnceAndReachesTheHeadphones() async {
        let controller = makeController()
        _ = await sync(controller)
        await wait("channel released") { controller.link == .idle }

        controller.setNoiseMode(.ambient)
        XCTAssertEqual(controller.status.noiseControl?.mode, .ambient) // before any Bluetooth traffic
        await wait("sent and released") { self.headphones.count == 2 && controller.link == .idle }
        XCTAssertEqual(memory.noise, [0x01, 0x01, 0x01, 0x00, 0x14, 0x00, 0x00])
        XCTAssertEqual(controller.status.noiseControl?.mode, .ambient)

        controller.setNoiseMode(.off)
        await wait("sent and released") { self.headphones.count == 3 && controller.link == .idle }
        XCTAssertEqual(memory.noise[1], 0x00)
        XCTAssertEqual(memory.noise[2], 0x01, "off keeps the selected mode")
        XCTAssertEqual(controller.status.noiseControl?.mode, .off)
    }

    func testDraggingTheAmbientSliderCollapsesToFewWrites() async {
        let controller = makeController()
        controller.hold()
        await wait("live") { controller.status.noiseControl != nil }
        var value = controller.status.noiseControl!
        value.mode = .ambient
        for level in UInt8(1)...UInt8(20) {
            value.ambientLevel = level
            controller.setNoiseControl(value, adjusting: true)
        }
        value.ambientLevel = 7
        controller.setNoiseControl(value)
        XCTAssertEqual(controller.status.noiseControl?.ambientLevel, 7)
        await wait("written") { self.memory.noise[4] == 7 && self.memory.noise[0] == 0x01 }
        XCTAssertLessThan(headphones[0].received(0x68, table: MDRDataType.table1).count, 5)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.status.noiseControl?.ambientLevel, 7, "no stale value bounced back")
        controller.release()
    }

    func testSwitchingSource() async {
        let controller = makeController()
        _ = await sync(controller)
        let phone = controller.status.nextDevice!
        let failure: String? = await withCheckedContinuation { continuation in
            controller.switchPlayback(to: phone) { continuation.resume(returning: $0) }
            XCTAssertEqual(controller.busyDevices, [phone.address])
        }
        XCTAssertNil(failure)
        XCTAssertEqual(controller.status.playingDevice?.name, "iPhone")
        XCTAssertTrue(controller.busyDevices.isEmpty)
        XCTAssertEqual(controller.status.nextDevice?.name, "MacBook")
    }

    func testRefusedSwitchExplainsWhy() async {
        let controller = makeController()
        _ = await sync(controller)
        memory.refuseSwitchWith = 0x02
        let failure: String? = await withCheckedContinuation { continuation in
            controller.switchToNextDevice { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(failure, "Can't switch during a call")
        XCTAssertEqual(notices, ["Can't switch during a call"])
        XCTAssertEqual(controller.status.playingDevice?.name, "MacBook")
    }

    func testConnectingAnotherDeviceWaitsUntilItShows() async {
        let controller = makeController()
        _ = await sync(controller)
        let tablet = controller.status.devices[2]
        XCTAssertFalse(tablet.isConnected)
        let failure: String? = await withCheckedContinuation { continuation in
            controller.connect(tablet) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(failure)
        XCTAssertEqual(controller.status.connectedDevices.map(\.name), ["MacBook", "iPhone", "iPad"])
    }

    func testFailedOpenReportsAndRollsBack() async {
        let controller = makeController()
        _ = await sync(controller)
        await wait("channel released") { controller.link == .idle }
        failOpen = "The headphones refused the control channel"
        controller.setSidetone(true)
        XCTAssertEqual(controller.status.sidetone, true)
        await wait("failed") { controller.link == .failed("The headphones refused the control channel") }
        XCTAssertEqual(controller.status.sidetone, false)
        XCTAssertEqual(notices, ["The headphones refused the control channel"])

        failOpen = nil
        unreachable = true
        let failure = await sync(controller)
        XCTAssertEqual(failure, "The headphones aren't connected to this device")
    }

    func testEqualizerPresetsAndBands() async {
        let controller = makeController()
        _ = await sync(controller)
        let info = try! XCTUnwrap(controller.capabilities?.equalizer)
        XCTAssertEqual(info.bandCount, 10)
        XCTAssertEqual(info.levels, -6...6)
        XCTAssertEqual(info.preset(0x16)?.title, "Bass Boost")
        XCTAssertEqual(controller.status.equalizer, Equalizer(presetID: 0x00, steps: [UInt8](repeating: 6, count: 10)))
        XCTAssertEqual(controller.status.equalizerAvailable, true)

        // A preset shows at once; its bands arrive with the headphones' answer.
        controller.selectEqualizerPreset(0x16)
        XCTAssertEqual(controller.status.equalizer?.presetID, 0x16)
        await wait("preset's bands") { controller.status.equalizer?.steps.first == 12 }
        XCTAssertEqual(memory.equalizerPreset, 0x16)

        // Moving a band of a fixed preset starts a custom one from where the bands are.
        controller.setEqualizerLevel(-2, band: 0, adjusting: true)
        controller.setEqualizerLevel(-4, band: 0)
        XCTAssertEqual(controller.status.equalizer?.presetID, 0xA0)
        await wait("written") { self.memory.equalizerBands[0xA0]?.first == 2 }
        XCTAssertEqual(memory.equalizerPreset, 0xA0)
        XCTAssertEqual(memory.equalizerBands[0xA0], [2, 11, 9, 7, 6, 6, 6, 6, 6, 6])
        XCTAssertEqual(memory.equalizerBands[0x16]?.first, 12, "the fixed preset itself is untouched")
        await wait("released") { controller.link == .idle }
        XCTAssertEqual(controller.status.equalizer, Equalizer(presetID: 0xA0, steps: [2, 11, 9, 7, 6, 6, 6, 6, 6, 6]))
    }

    func testCapabilitiesSavedBeforeTheEqualizerAreToppedUp() async {
        let first = makeController()
        _ = await sync(first)
        var old = first.snapshot
        old.capabilities?.equalizer = nil
        old.capabilities?.equalizerProbed = nil
        old.status.equalizer = nil

        let second = makeController(snapshot: old)
        _ = await sync(second, .equalizer)
        XCTAssertEqual(second.capabilities?.equalizer?.bandCount, 10)
        XCTAssertEqual(second.capabilities?.equalizerProbed, true)
        XCTAssertEqual(second.status.equalizer?.presetID, 0x00)
        // Only the equalizer was asked about, not the whole handshake again.
        XCTAssertTrue(headphones[1].received(0x06, table: MDRDataType.table1).isEmpty)
        XCTAssertEqual(headphones[1].received(0x50, table: MDRDataType.table1).count, 1)
    }

    func testTogglesWriteAndConfirm() async {
        let controller = makeController()
        _ = await sync(controller)
        controller.setSidetone(true)
        controller.setAutoSwitch(false)
        await wait("written") { self.memory.sidetoneOff == 0x00 && self.memory.autoSwitch == 0x00 }
        await wait("released") { controller.link == .idle }
        XCTAssertEqual(controller.status.sidetone, true)
        XCTAssertEqual(controller.status.autoSwitch, false)
    }
}
