import XCTest
@testable import MDRKit

/// Replies captured from a 1000X The ColleXion (firmware 1.3.0).
final class MDRSettingsTests: XCTestCase {
    func testRealColleXionAdvertisesMicSettings() {
        let payload = hex("""
            07 00 2E 10 FF 12 FF 13 FF 14 FF 15 FF 16 FF 17 FF 23 FF 25 3A 27 FF 20 FF 57 14 56 FF 6D 0B 71 02 90 FF
            A1 15 C1 FF C2 FF E2 1E F1 3C FC 0D 69 2E F9 45 D1 3F D3 2D 94 FF 41 33 42 3E 44 FF FF 31 F4 26 D2 23 19 FF
            EB 10 EC 12 E6 0E EA 2C E7 1D B7 18 FD 2F B6 1A B0 46 B2 47 B8 22 34 43
            """)
        guard case let .supportFunctions(functions)? = MDRParser.parseT1(payload) else { return XCTFail() }
        XCTAssertEqual(functions.count, 46)
        XCTAssertTrue(functions.contains(T1Function.speakToChat))
        XCTAssertEqual(T1Function.generalSettings.filter(functions.contains), [0xD1, 0xD2, 0xD3])
    }

    func testRealGeneralSettingCapabilities() {
        let sidetone = hex("D1 D1 00 01 10") + ascii("SIDETONE_SETTING") + [0x18] + ascii("SIDETONE_SETTING_SUMMARY")
        XCTAssertEqual(MDRParser.parseT1(sidetone), .generalSettingInfo(GeneralSettingInfo(
            index: 0xD1, isBoolean: true, subject: "SIDETONE_SETTING", summary: "SIDETONE_SETTING_SUMMARY")))
        let touch = hex("D1 D3 00 01 13") + ascii("TOUCH_PANEL_SETTING") + [0x00]
        guard case let .generalSettingInfo(info)? = MDRParser.parseT1(touch) else { return XCTFail() }
        XCTAssertEqual(info.summary, "")
        XCTAssertFalse(info.isSidetone)
    }

    func testRealSettingValues() {
        XCTAssertEqual(MDRParser.parseT1(hex("D7 D1 00 01")), .generalSetting(index: 0xD1, on: false))
        XCTAssertEqual(MDRParser.parseT1(hex("D9 D2 00 00")), .generalSetting(index: 0xD2, on: true))
        XCTAssertEqual(MDRParser.parseT1(hex("F7 0C 00 01")), .speakToChat(enabled: true))
        XCTAssertEqual(MDRParser.parseT1(hex("FB 0C 00 00")),
                       .speakToChatDetail(SpeakToChatDetail(sensitivity: .auto, timeout: .short)))
        XCTAssertEqual(MDRParser.parseT2(hex("F7 0B 00 01")), .micMute(MicMuteSettings(buttonMutes: true, playsSound: false)))
        XCTAssertEqual(MDRParser.parseT2(hex("F9 0B 01 00")), .micMute(MicMuteSettings(buttonMutes: false, playsSound: true)))
    }

    func testUnrelatedOrMalformedSettingsAreIgnored() {
        XCTAssertEqual(MDRParser.parseT1(hex("F7 0D 00")), .other(command: 0xF7))
        XCTAssertEqual(MDRParser.parseT1(hex("D7 D1 01 02")), .other(command: 0xD7))   // list-type setting
        XCTAssertNil(MDRParser.parseT1(hex("F7 0C 05")))
        XCTAssertNil(MDRParser.parseT1(hex("FB 0C 09 00")))
        XCTAssertNil(MDRParser.parseT1(hex("D1 D1 00 01 10 41")))
        XCTAssertEqual(MDRParser.parseT2(hex("F7 0A 00")), .other(command: 0xF7))
    }

    func testRequestLayouts() {
        XCTAssertEqual(MDRRequest.generalSettingInfo(0xD1), hex("D0 D1 01"))
        XCTAssertEqual(MDRRequest.generalSetting(0xD1), hex("D6 D1"))
        XCTAssertEqual(MDRRequest.setGeneralSetting(0xD1, on: true), hex("D8 D1 00 00"))
        XCTAssertEqual(MDRRequest.setGeneralSetting(0xD1, on: false), hex("D8 D1 00 01"))
        XCTAssertEqual(MDRRequest.speakToChat, hex("F6 0C"))
        XCTAssertEqual(MDRRequest.setSpeakToChat(true), hex("F8 0C 00 01"))
        XCTAssertEqual(MDRRequest.speakToChatDetail, hex("FA 0C"))
        XCTAssertEqual(MDRRequest.setSpeakToChatDetail(SpeakToChatDetail(sensitivity: .low, timeout: .never)), hex("FC 0C 02 03"))
        XCTAssertEqual(MDRRequest.micMute, hex("F6 0B"))
        XCTAssertEqual(MDRRequest.setMicMute(MicMuteSettings(buttonMutes: true, playsSound: false)), hex("F8 0B 00 01"))
    }

    private func hex(_ text: String) -> [UInt8] {
        text.split(whereSeparator: \.isWhitespace).map { UInt8($0, radix: 16)! }
    }

    private func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }
}

final class MDRNoiseControlTests: XCTestCase {
    private func hex(_ text: String) -> [UInt8] {
        text.split(whereSeparator: \.isWhitespace).map { UInt8($0, radix: 16)! }
    }

    func testVariantFollowsWhatTheHeadphonesAdvertise() {
        XCTAssertEqual(NoiseControlVariant(supported: [0x6D, 0x69]), .adaptive) // The ColleXion
        XCTAssertEqual(NoiseControlVariant(supported: [0x6B]), .dual)
        XCTAssertEqual(NoiseControlVariant(supported: [0x67]), .ambientOnly)
        XCTAssertNil(NoiseControlVariant(supported: [0xFC]))
    }

    func testAdaptiveLayout() {
        let ambient = NoiseControl(variant: .adaptive, isEnabled: true, isAmbient: true, ambientLevel: 12,
                                   focusOnVoice: true, adjustsAutomatically: false, sensitivity: .high)
        XCTAssertEqual(MDRParser.parseT1(hex("67 19 01 01 01 01 0C 00 01")), .noiseControl(ambient, adjusting: false))
        XCTAssertEqual(MDRParser.parseT1(hex("69 19 00 01 01 01 0C 00 01")), .noiseControl(ambient, adjusting: true))
        XCTAssertEqual(MDRRequest.setNoiseControl(ambient), hex("68 19 01 01 01 01 0C 00 01"))
        XCTAssertEqual(MDRRequest.setNoiseControl(ambient, adjusting: true), hex("68 19 00 01 01 01 0C 00 01"))
        XCTAssertEqual(MDRRequest.noiseControl(.adaptive), hex("66 19"))
        XCTAssertEqual(ambient.mode, .ambient)
    }

    func testDualAndAmbientOnlyLayouts() {
        let cancelling = NoiseControl(variant: .dual, isEnabled: true, isAmbient: false, ambientLevel: 20, focusOnVoice: false)
        XCTAssertEqual(MDRParser.parseT1(hex("67 17 01 01 00 00 14")), .noiseControl(cancelling, adjusting: false))
        XCTAssertEqual(MDRRequest.setNoiseControl(cancelling), hex("68 17 01 01 00 00 14"))
        XCTAssertEqual(cancelling.mode, .noiseCancelling)

        let ambientOnly = NoiseControl(variant: .ambientOnly, isEnabled: true, isAmbient: true, ambientLevel: 5, focusOnVoice: true)
        XCTAssertEqual(MDRParser.parseT1(hex("67 22 01 01 01 05")), .noiseControl(ambientOnly, adjusting: false))
        XCTAssertEqual(MDRRequest.setNoiseControl(ambientOnly), hex("68 22 01 01 01 05"))
        XCTAssertEqual(ambientOnly.availableModes, [.ambient, .off])
    }

    func testModeChangesKeepTheRest() {
        var value = NoiseControl(variant: .adaptive, isEnabled: true, isAmbient: true, ambientLevel: 9, focusOnVoice: false,
                                 adjustsAutomatically: true, sensitivity: .standard)
        value.mode = .off
        XCTAssertEqual(value.mode, .off)
        XCTAssertTrue(value.isAmbient, "the headphones remember the mode while off")
        value.mode = .noiseCancelling
        XCTAssertEqual(MDRRequest.setNoiseControl(value), hex("68 19 01 01 00 00 09 01 00"))
    }

    func testOtherNoiseMessagesAreIgnored() {
        XCTAssertEqual(MDRParser.parseT1(hex("67 30 02")), .other(command: 0x67)) // button assignment
        XCTAssertEqual(MDRParser.parseT1(hex("67 19 01 01")), .other(command: 0x67)) // truncated
    }
}
