import AppKit

/// One item of a menu, described so that it can be created once and then updated in place.
///
/// The menu is redrawn from the headphones' state many times while it's open. Recreating the items each time would
/// tear a slider out from under the pointer mid-drag and close open submenus, so items are matched by `key`: those
/// that stay are only updated, and the rest are inserted or removed around them.
struct MenuEntry {
    let key: String
    let make: () -> NSMenuItem
    let update: (NSMenuItem) -> Void
}

@MainActor
final class MenuRenderer {
    let menu: NSMenu
    private var keys: [String] = []
    private var items: [String: NSMenuItem] = [:]
    private var children: [String: MenuRenderer] = [:]

    init(menu: NSMenu) {
        self.menu = menu
        menu.autoenablesItems = false
    }

    func render(_ entries: [MenuEntry]) {
        let wanted = Set(entries.map(\.key))
        precondition(wanted.count == entries.count, "menu entry keys must be unique")
        for key in keys where !wanted.contains(key) {
            if let item = items.removeValue(forKey: key) { menu.removeItem(item) }
            children[key] = nil
        }
        keys.removeAll { !wanted.contains($0) }

        for (index, entry) in entries.enumerated() {
            if index < keys.count, keys[index] == entry.key {
                // Already in place.
            } else if let current = keys.firstIndex(of: entry.key), let item = items[entry.key] {
                menu.removeItem(item)
                menu.insertItem(item, at: index)
                keys.remove(at: current)
                keys.insert(entry.key, at: index)
            } else {
                let item = entry.make()
                items[entry.key] = item
                menu.insertItem(item, at: index)
                keys.insert(entry.key, at: index)
            }
            entry.update(items[entry.key]!)
        }
    }

    // MARK: Entry kinds

    static func separator(_ key: String) -> MenuEntry {
        MenuEntry(key: key, make: { .separator() }, update: { _ in })
    }

    static func sectionHeader(_ key: String, _ title: String) -> MenuEntry {
        MenuEntry(key: key, make: {
            if #available(macOS 14, *) { return .sectionHeader(title: title) }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }, update: { $0.title = title })
    }

    /// A line of text that can't be chosen.
    static func info(_ key: String, _ title: String, symbol: String? = nil) -> MenuEntry {
        MenuEntry(key: key, make: {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }, update: { item in
            item.title = title
            item.image = symbol.flatMap(templateSymbol)
        })
    }

    /// A standard menu item. Choosing it closes the menu, as usual.
    static func command(_ key: String, _ title: String, symbol: String? = nil, checked: Bool? = nil, enabled: Bool = true,
                        keyEquivalent: String = "", modifiers: NSEvent.ModifierFlags = .command, toolTip: String? = nil,
                        _ handler: @escaping () -> Void) -> MenuEntry {
        MenuEntry(key: key, make: { ClosureMenuItem() }, update: { item in
            guard let item = item as? ClosureMenuItem else { return }
            item.title = title
            item.handler = handler
            item.isEnabled = enabled
            item.state = checked == true ? .on : .off
            item.image = symbol.flatMap(templateSymbol)
            item.keyEquivalent = keyEquivalent
            item.keyEquivalentModifierMask = modifiers
            item.toolTip = toolTip
        })
    }

    /// An item drawn by a custom view, which stays in the menu (and keeps the menu open) across updates.
    static func view<View: NSView>(_ key: String, _ make: @escaping () -> View, _ update: @escaping (View) -> Void) -> MenuEntry {
        MenuEntry(key: key, make: {
            let item = NSMenuItem()
            item.view = make()
            return item
        }, update: { item in
            if let view = item.view as? View { update(view) }
        })
    }

    /// A submenu, with its own entries. For another level, build the inner one with `child(key).submenu(…)`.
    func submenu(_ key: String, _ title: String, enabled: Bool = true, toolTip: String? = nil, _ entries: [MenuEntry]) -> MenuEntry {
        let child = child(key)
        return MenuEntry(key: key, make: {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = child.menu
            return item
        }, update: { item in
            item.title = title
            item.isEnabled = enabled
            item.toolTip = toolTip
            child.render(entries)
        })
    }

    /// The renderer of the submenu with this key.
    func child(_ key: String) -> MenuRenderer {
        if let existing = children[key] { return existing }
        let created = MenuRenderer(menu: NSMenu())
        children[key] = created
        return created
    }

    private static func templateSymbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    var handler: (() -> Void)?

    init() {
        super.init(title: "", action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler?() }
}
