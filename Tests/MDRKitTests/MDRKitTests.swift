import XCTest
@testable import MDRKit

final class MDRCodecTests: XCTestCase {
    func testAckMatchesKnownWireBytes() {
        // ACK with sequence 1, as documented by the original SonyHeadphonesClient.
        XCTAssertEqual(MDRCodec.encode(MDRPacket(dataType: MDRDataType.ack, sequence: 1)),
                       [0x3E, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x02, 0x3C])
    }

    func testProtocolInfoRequestEncoding() {
        let packet = MDRPacket(dataType: MDRDataType.table1, sequence: 0, payload: MDRRequest.protocolInfo)
        XCTAssertEqual(MDRCodec.encode(packet), [0x3E, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x0E, 0x3C])
    }

    func testEscapingRoundTrip() {
        let packet = MDRPacket(dataType: MDRDataType.table2, sequence: 1, payload: [0x3C, 0x3D, 0x3E, 0x00, 0xFF, 0x3C])
        let wire = MDRCodec.encode(packet)
        XCTAssertEqual(wire.first, 0x3E)
        XCTAssertEqual(wire.last, 0x3C)
        XCTAssertFalse(wire.dropFirst().dropLast().contains { (0x3C...0x3E).contains($0) && $0 != 0x3D },
                       "markers must never appear inside a frame")
        var decoder = MDRStreamDecoder()
        XCTAssertEqual(decoder.feed(wire), [packet])
    }

    func testStreamDecoderHandlesSplitsCoalescingAndGarbage() {
        let a = MDRPacket(dataType: MDRDataType.table2, sequence: 0, payload: [0x37, 0x01, 0x01])
        let b = MDRPacket(dataType: MDRDataType.ack, sequence: 1)
        let stream = [0x99, 0x3E, 0x01] /* truncated frame */ + MDRCodec.encode(a) + MDRCodec.encode(b)
        var decoder = MDRStreamDecoder()
        var out: [MDRPacket] = []
        for chunk in stride(from: 0, to: stream.count, by: 3) {
            out += decoder.feed(stream[chunk..<min(chunk + 3, stream.count)])
        }
        XCTAssertEqual(out, [a, b])
    }

    func testBadChecksumIsDropped() {
        var wire = MDRCodec.encode(MDRPacket(dataType: MDRDataType.table2, sequence: 0, payload: [0x01, 0x02]))
        wire[wire.count - 2] &+= 1
        var decoder = MDRStreamDecoder()
        XCTAssertEqual(decoder.feed(wire), [])
    }
}

final class MDRParserTests: XCTestCase {
    private func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testProtocolInfo() {
        let info = MDRParser.protocolInfo([0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00])
        XCTAssertEqual(info, ProtocolInfo(version: 0x0200, hasTable1: true, hasTable2: true))
    }

    func testSupportFunctionsT2() {
        let message = MDRParser.parseT2([0x07, 0x00, 0x03, 0x31, 0x00, 0x32, 0x00, 0x20, 0x01])
        XCTAssertEqual(message, .supportFunctions([0x31, 0x32, 0x20]))
    }

    func testPairedDeviceListWithClassOfDevice() {
        let mac = ascii("AA:BB:CC:DD:EE:01"), phone = ascii("AA:BB:CC:DD:EE:02"), tablet = ascii("AA:BB:CC:DD:EE:03")
        var payload: [UInt8] = [0x37, 0x02, 0x03]
        payload += mac + [0x01, 0x38, 0x01, 0x0C] + [3] + ascii("Mac")
        payload += phone + [0x02, 0x5A, 0x02, 0x0C] + [5] + ascii("Phone")
        payload += tablet + [0x00, 0x00, 0x01, 0x14] + [6] + ascii("Tablet")
        payload += [0x02] // playback slot

        guard case let .pairedDevices(devices, source)? = MDRParser.parseT2(payload) else {
            return XCTFail("expected a device list")
        }
        XCTAssertEqual(source, .pairingWithClassOfDevice)
        XCTAssertEqual(devices.map(\.name), ["Mac", "Phone", "Tablet"])
        XCTAssertEqual(devices.map(\.isConnected), [true, true, false])
        XCTAssertEqual(devices.map(\.isPlaying), [false, true, false])
        XCTAssertEqual(devices[1].classOfDevice, 0x5A020C)
        XCTAssertEqual(devices[0].address, "AA:BB:CC:DD:EE:01")
        XCTAssertEqual(devices[0].normalizedAddress, "AABBCCDDEE01")
    }

    /// The layout of a list captured from a 1000X The ColleXion (FW 1.3.0), with the addresses and device names
    /// replaced. Note the 0xFFFFFF class of device for the disconnected entry and the UTF-8 name.
    func testRealColleXionDeviceList() {
        let hex = """
        37 02 03 41 41 3A 41 41 3A 41 41 3A 41 41 3A 41 41 3A 30 31 02 38 01 0C 0B 4D 61 63 42 6F 6F 6B 20 50 72 6F
        41 41 3A 41 41 3A 41 41 3A 41 41 3A 41 41 3A 30 32 01 7A 02 0C 06 69 50 68 6F 6E 65 41 41 3A 41 41 3A 41 41
        3A 41 41 3A 41 41 3A 30 33 00 FF FF FF 0A 43 61 66 C3 A9 20 69 50 61 64 02
        """
        let payload = hex.split(whereSeparator: \.isWhitespace).map { UInt8($0, radix: 16)! }
        guard case let .pairedDevices(devices, _)? = MDRParser.parseT2(payload) else { return XCTFail() }
        XCTAssertEqual(devices.map(\.name), ["MacBook Pro", "iPhone", "Café iPad"])
        XCTAssertEqual(devices.map(\.address), ["AA:AA:AA:AA:AA:01", "AA:AA:AA:AA:AA:02", "AA:AA:AA:AA:AA:03"])
        XCTAssertEqual(devices.map(\.connectionSlot), [2, 1, 0])
        XCTAssertEqual(devices.map(\.isPlaying), [true, false, false])
        XCTAssertEqual(devices.map(\.kind), [.laptop, .phone, .unknown])
    }

    func testRealColleXionSupportsSourceSwitching() {
        let payload: [UInt8] = [0x07, 0x00, 0x11, 0x42, 0x41, 0x52, 0xFF, 0x54, 0xFF, 0x60, 0xFF, 0x61, 0xFF, 0xF2, 0xFF,
                                0xF5, 0x28, 0x22, 0x39, 0xF9, 0x35, 0x63, 0xFF, 0x21, 0xFF, 0x23, 0xFF, 0xF8, 0x34,
                                0xFD, 0xFF, 0x33, 0x05, 0x34, 0xFF, 0x31, 0xFF]
        guard case let .supportFunctions(functions)? = MDRParser.parseT2(payload) else { return XCTFail() }
        XCTAssertTrue(functions.contains(T2Function.sourceSwitchControl))
        XCTAssertTrue(functions.contains(T2Function.pairingWithClassOfDeviceLE))
    }

    func testDisconnectedDeviceIsNeverPlayingEvenIfSlotMatches() {
        var payload: [UInt8] = [0x39, 0x00, 0x01]
        payload += ascii("AA:BB:CC:DD:EE:01") + [0x00] + [1] + ascii("X")
        payload += [0x00]
        guard case let .pairedDevices(devices, _)? = MDRParser.parseT2(payload) else { return XCTFail() }
        XCTAssertEqual(devices.first?.isPlaying, false)
    }

    func testSourceSwitchNotifications() {
        XCTAssertEqual(MDRParser.parseT2([0x39, 0x01, 0x00, 0x00]), .autoSwitch(enabled: false))
        XCTAssertEqual(MDRParser.parseT2([0x37, 0x01, 0x01]), .autoSwitch(enabled: true))
        XCTAssertEqual(MDRParser.parseT2([0x3D, 0x01, 0x02] + ascii("AA:BB:CC:DD:EE:02")),
                       .sourceSwitchResult(code: 0x02, address: "AA:BB:CC:DD:EE:02"))
        XCTAssertEqual(MDRParser.parseT2([0x3D, 0x02, 0x01, 0x10] + ascii("AA:BB:CC:DD:EE:03")),
                       .connectivityResult(action: 0x01, result: 0x10, address: "AA:BB:CC:DD:EE:03"))
    }

    func testTruncatedPayloadsDoNotCrash() {
        XCTAssertNil(MDRParser.parseT2([0x37, 0x02, 0x01, 0x41]))
        XCTAssertNil(MDRParser.parseT2([0x3D, 0x01, 0x00, 0x41]))
        XCTAssertEqual(MDRParser.parseT2([0x50, 0x01]), .other(command: 0x50))
    }

    func testRequestLayouts() {
        let address = ascii("AA:BB:CC:DD:EE:02")
        XCTAssertEqual(MDRRequest.switchSource(to: address), [0x3C, 0x01] + address)
        XCTAssertEqual(MDRRequest.connectivity(.connect, .pairingWithClassOfDevice, address: address), [0x3C, 0x02, 0x01] + address)
        XCTAssertEqual(MDRRequest.setAutoSwitch(false), [0x38, 0x01, 0x00])
        XCTAssertEqual(MDRRequest.pairedDevices(.pairingClassic), [0x36, 0x00])
    }
}
