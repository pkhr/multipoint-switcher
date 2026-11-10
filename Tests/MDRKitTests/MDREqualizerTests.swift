import XCTest
@testable import MDRKit

final class MDREqualizerTests: XCTestCase {
    private func hex(_ text: String) -> [UInt8] {
        text.split(whereSeparator: \.isWhitespace).map { UInt8($0, radix: 16)! }
    }

    private let info = EqualizerInfo(variant: .customizableWithReasons, bandCount: 10, stepCount: 13, presets: [
        EqualizerPreset(id: 0x00), EqualizerPreset(id: 0x10), EqualizerPreset(id: 0xA0), EqualizerPreset(id: 0xA1),
    ])

    func testVariantFollowsWhatTheHeadphonesAdvertise() {
        XCTAssertEqual(EqualizerVariant(supported: [0x57, 0x56]), .customizableWithReasons) // The ColleXion
        XCTAssertEqual(EqualizerVariant(supported: [0x50]), .customizable)
        XCTAssertEqual(EqualizerVariant(supported: [0x52]), .presetsOnly)
        XCTAssertNil(EqualizerVariant(supported: [0x53, 0x6D])) // the ULT layout isn't supported
    }

    func testCapability() {
        let payload = hex("51 04 0A 0D 03 00 00 10 06") + Array("Bright".utf8) + hex("A0 00")
        guard case let .equalizerInfo(parsed)? = MDRParser.parseT1(payload) else { return XCTFail() }
        XCTAssertEqual(parsed.variant, .customizableWithReasons)
        XCTAssertEqual(parsed.bandCount, 10)
        XCTAssertEqual(parsed.stepCount, 13)
        XCTAssertEqual(parsed.presets.map(\.id), [0x00, 0x10, 0xA0])
        XCTAssertEqual(parsed.presets.map(\.title), ["Off", "Bright", "Manual"])
        XCTAssertEqual(parsed.levels, -6...6)
        XCTAssertEqual(parsed.bandLabels.count, 10)
        XCTAssertTrue(parsed.isCustomizable)
        XCTAssertEqual(MDRRequest.equalizerInfo(.customizableWithReasons), hex("50 04 01"))
    }

    func testSixBandLayoutCountsFromMinusTen() {
        let classic = EqualizerInfo(variant: .customizable, bandCount: 6, stepCount: 21, presets: [])
        XCTAssertEqual(classic.levels, -10...10)
        XCTAssertEqual(classic.bandLabels.first, "Bass")
        XCTAssertEqual(Equalizer(presetID: 0xA0, steps: [10, 12, 0, 20, 10, 10]).levels(in: classic), [0, 2, -10, 10, 0, 0])
    }

    func testValues() {
        let value = Equalizer(presetID: 0x10, steps: [5, 5, 6, 6, 7, 8, 9, 10, 11, 11])
        XCTAssertEqual(MDRParser.parseT1(hex("57 00 10 0A 05 05 06 06 07 08 09 0A 0B 0B")), .equalizer(value))
        XCTAssertEqual(MDRParser.parseT1(hex("59 04 10 0A 05 05 06 06 07 08 09 0A 0B 0B")), .equalizer(value))
        XCTAssertEqual(value.levels(in: info), [-1, -1, 0, 0, 1, 2, 3, 4, 5, 5])
        XCTAssertEqual(MDRParser.parseT1(hex("59 00 A0")), .equalizer(Equalizer(presetID: 0xA0)))
        XCTAssertEqual(MDRRequest.equalizer, hex("56 00"))
        XCTAssertEqual(MDRRequest.selectEqualizerPreset(0x10), hex("58 00 10 00"))
    }

    func testSettingBands() {
        var value = Equalizer(presetID: 0xA0, steps: [UInt8](repeating: 6, count: 10))
        value.setLevel(4, band: 0, in: info)
        value.setLevel(-99, band: 9, in: info) // clamped
        value.setLevel(1, band: 42, in: info) // ignored
        XCTAssertEqual(value.steps, [10, 6, 6, 6, 6, 6, 6, 6, 6, 0])
        XCTAssertEqual(MDRRequest.setEqualizer(value), hex("58 00 A0 0A 0A 06 06 06 06 06 06 06 06 00"))
    }

    func testAvailability() {
        XCTAssertEqual(MDRParser.parseT1(hex("53 00 00 00")), .equalizerAvailable(true))
        XCTAssertEqual(MDRParser.parseT1(hex("55 00 01 01 00")), .equalizerAvailable(false)) // unavailable: in a call
        XCTAssertEqual(MDRRequest.equalizerAvailability(.customizableWithReasons), hex("52 04"))
    }

    /// Replies captured from a 1000X The ColleXion (firmware 1.3.0).
    func testRealColleXionEqualizer() {
        guard case let .equalizerInfo(real)? = MDRParser.parseT1(hex("51 04 0A 0D 09 00 00 30 00 31 00 32 00 33 00 20 00 A0 00 A1 00 A2 00")) else {
            return XCTFail()
        }
        XCTAssertEqual(real.bandCount, 10)
        XCTAssertEqual(real.levels, -6...6)
        XCTAssertEqual(real.presets.map(\.title), ["Off", "Heavy", "Clear", "Hard", "Soft", "Gaming", "Manual", "Custom 1", "Custom 2"])
        guard case let .equalizer(value)? = MDRParser.parseT1(hex("57 00 A1 0A 05 05 06 06 06 06 06 06 07 07")) else { return XCTFail() }
        XCTAssertEqual(real.preset(value.presetID)?.title, "Custom 1")
        XCTAssertEqual(value.levels(in: real), [-1, -1, 0, 0, 0, 0, 0, 0, 1, 1])
        XCTAssertEqual(MDRParser.parseT1(hex("53 04 00 00")), .equalizerAvailable(true))
    }

    func testPresetTitles() {
        XCTAssertEqual(EqualizerPreset(id: 0x16, name: "ignored").title, "Bass Boost")
        XCTAssertEqual(EqualizerPreset(id: 0xB0, name: "Studio Mix").title, "Studio Mix")
        XCTAssertEqual(EqualizerPreset(id: 0xB1, name: "ARTIST_COLLAB_TWO").title, "Artist Collab Two")
        XCTAssertEqual(EqualizerPreset(id: 0xB2).title, "Preset 178")
        XCTAssertTrue(EqualizerPreset(id: 0xA1).isCustom)
        XCTAssertFalse(EqualizerPreset(id: 0x10).isCustom)
        XCTAssertEqual(info.customPreset?.id, 0xA0)
    }

    func testOtherOrMalformedMessagesAreIgnored() {
        XCTAssertEqual(MDRParser.parseT1(hex("57 01 05")), .other(command: 0x57)) // the bass-boost message
        XCTAssertEqual(MDRParser.parseT1(hex("57 00 10 0A 05")), .other(command: 0x57)) // truncated bands
        XCTAssertEqual(MDRParser.parseT1(hex("51 04 0A 0D 02 00 00 10 06 42")), .other(command: 0x51)) // truncated name
        XCTAssertEqual(MDRParser.parseT1(hex("51 03 0A 0D 00 00")), .other(command: 0x51)) // the ULT layout
    }
}
