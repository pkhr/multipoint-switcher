import XCTest
import HeadphoneKit
import MDRKit

final class EqualizerPresetNamesTests: XCTestCase {
    private let suite = "EqualizerPresetNamesTests"
    private var names: EqualizerPresetNames!
    private let info = EqualizerInfo(variant: .customizableWithReasons, bandCount: 10, stepCount: 13,
                                     presets: [0x00, 0x30, 0x31, 0xA0, 0xA1, 0xA2].map { EqualizerPreset(id: $0) })

    override func setUp() {
        UserDefaults().removePersistentDomain(forName: suite)
        names = EqualizerPresetNames(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testCustomPresetsTakeYourName() {
        XCTAssertEqual(names.title(EqualizerPreset(id: 0xA1)), "Custom 1")
        names.setName("  Neutral ", for: 0xA1)
        names.setName("Studio", for: 0xA2)
        XCTAssertEqual(names.title(EqualizerPreset(id: 0xA1)), "Neutral")
        XCTAssertEqual(names.title(0xA2, in: info), "Studio")
        XCTAssertEqual(names.title(0xA0, in: info), "Manual")
        XCTAssertEqual(EqualizerPresetNames(defaults: UserDefaults(suiteName: suite)!).name(for: 0xA1), "Neutral", "kept")

        names.setName("", for: 0xA1)
        XCTAssertEqual(names.title(EqualizerPreset(id: 0xA1)), "Custom 1")
    }

    func testFixedPresetsKeepTheirs() {
        names.setName("Mine", for: 0x30)
        XCTAssertEqual(names.title(EqualizerPreset(id: 0x30)), "Heavy")
    }

    func testFindingAPresetByEitherName() {
        names.setName("Neutral", for: 0xA1)
        XCTAssertEqual(names.presets(matching: "neutral", in: info).map(\.id), [0xA1])
        XCTAssertEqual(names.presets(matching: "Custom 1", in: info).map(\.id), [0xA1])
        XCTAssertEqual(names.presets(matching: "custom", in: info).map(\.id), [0xA1, 0xA2]) // ambiguous
        XCTAssertEqual(names.presets(matching: "clear", in: info).map(\.id), [0x31])
        XCTAssertTrue(names.presets(matching: "jazz", in: info).isEmpty)
    }
}
