import Foundation
import MDRKit

/// Names you've given the presets whose bands you set yourself: "Custom 1" as "Neutral", say.
///
/// The headphones have nowhere to keep a name, only the bands, so each app remembers the names itself: what you
/// call a preset on the Mac isn't known to the iPhone, and the other way round.
public struct EqualizerPresetNames {
    private static let key = "equalizerPresetNames"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var names: [String: String] { defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:] }

    /// The name given to a preset, if any.
    public func name(for id: UInt8) -> String? { names[String(id)] }

    /// Names a preset; nil or blank goes back to the headphones' own name for it.
    public func setName(_ name: String?, for id: UInt8) {
        var all = names
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        all[String(id)] = trimmed.isEmpty ? nil : trimmed
        defaults.set(all, forKey: Self.key)
    }

    /// What to call a preset: your name for a custom one, otherwise its own.
    public func title(_ preset: EqualizerPreset) -> String {
        preset.isCustom ? name(for: preset.id) ?? preset.title : preset.title
    }

    /// What to call the preset with this number, which the headphones may not have listed.
    public func title(_ id: UInt8, in info: EqualizerInfo?) -> String {
        title(info?.preset(id) ?? EqualizerPreset(id: id))
    }

    /// The presets whose name, either one, matches the text; an exact match wins over a partial one.
    public func presets(matching text: String, in info: EqualizerInfo) -> [EqualizerPreset] {
        let wanted = text.trimmingCharacters(in: .whitespaces)
        let exact = info.presets.filter { [title($0), $0.title].contains { $0.caseInsensitiveCompare(wanted) == .orderedSame } }
        if !exact.isEmpty { return exact }
        return info.presets.filter { [title($0), $0.title].contains { $0.localizedCaseInsensitiveContains(wanted) } }
    }
}
