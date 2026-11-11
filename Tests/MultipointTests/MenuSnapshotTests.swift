import AppKit
import XCTest
@testable import Multipoint

/// Draws the menu bar app's menu (in demo mode, against simulated headphones) into PNG files, for looking at the
/// layout without opening the real menu. Standard items are approximated; the custom views are the real ones.
///
///     MULTIPOINT_SNAPSHOT_DIR=/some/dir swift test --filter MenuSnapshotTests
@MainActor
final class MenuSnapshotTests: XCTestCase {
    func testRenderMenu() async throws {
        guard let directory = ProcessInfo.processInfo.environment["MULTIPOINT_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MULTIPOINT_SNAPSHOT_DIR to render the menu")
        }
        setenv("MULTIPOINT_DEMO", "1", 1)
        _ = NSApplication.shared
        let app = AppController()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let menu = app.menuForTesting
        app.menuNeedsUpdate(menu)
        app.menuWillOpen(menu)
        try await Task.sleep(for: .milliseconds(400))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            try snapshot(menu, appearance: appearance).write(to: URL(fileURLWithPath: "\(directory)/menu-\(suffix).png"))
            if let equalizer = menu.items.first(where: { $0.title.hasPrefix("Equalizer") })?.submenu {
                try snapshot(equalizer, appearance: appearance).write(to: URL(fileURLWithPath: "\(directory)/equalizer-\(suffix).png"))
            }
            if let microphone = menu.items.first(where: { $0.title == "Microphone" })?.submenu {
                try snapshot(microphone, appearance: appearance).write(to: URL(fileURLWithPath: "\(directory)/microphone-\(suffix).png"))
            }
        }

        // Ambient mode adds the level slider and its options.
        let modes = try XCTUnwrap(menu.items.compactMap { $0.view as? NoiseModesView }.first)
        modes.onSelect?(.ambient)
        try await Task.sleep(for: .milliseconds(400))
        try snapshot(menu, appearance: .aqua).write(to: URL(fileURLWithPath: "\(directory)/menu-ambient-light.png"))
        try snapshot(menu, appearance: .darkAqua).write(to: URL(fileURLWithPath: "\(directory)/menu-ambient-dark.png"))
        app.menuDidClose(menu)
    }

    /// Draws the About window's contents the same way.
    func testRenderAbout() throws {
        guard let directory = ProcessInfo.processInfo.environment["MULTIPOINT_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MULTIPOINT_SNAPSHOT_DIR to render the About window")
        }
        _ = NSApplication.shared
        let photo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("iOS/App/Assets.xcassets/Headphones.imageset/Headphones.png")
        let view = AboutView(photo: NSImage(contentsOf: photo))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(directory)/about.png"))

        // And the real window opens, sized to its contents.
        AboutWindowController.shared.show()
        let about = try XCTUnwrap(AboutWindowController.shared.window)
        XCTAssertTrue(about.isVisible)
        XCTAssertEqual(about.contentView?.frame.width, AboutView.width)
        about.close()
    }

    private func snapshot(_ menu: NSMenu, appearance: NSAppearance.Name) throws -> Data {
        let width = MenuMetrics.width
        var rows: [NSView] = []
        for item in menu.items where !item.isHidden {
            if let view = item.view {
                // A wrapper takes the position; the item's view stays at its own origin.
                let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: view.frame.height))
                view.removeFromSuperview()
                view.frame = host.bounds
                host.addSubview(view)
                rows.append(host)
            } else if item.isSeparatorItem {
                let line = NSBox(frame: NSRect(x: 0, y: 0, width: width, height: 11))
                line.boxType = .custom
                line.borderWidth = 0
                let rule = NSView(frame: NSRect(x: 14, y: 5, width: width - 28, height: 1))
                rule.wantsLayer = true
                rule.layer?.backgroundColor = NSColor.separatorColor.cgColor
                line.addSubview(rule)
                rows.append(line)
            } else {
                let isHeader: Bool
                if #available(macOS 14, *) { isHeader = item.isSectionHeader } else { isHeader = false }
                var title = item.title
                if item.state == .on { title = "✓ " + title }
                if item.hasSubmenu { title += "   ›" }
                if !item.keyEquivalent.isEmpty { title += "   [\(item.keyEquivalent)]" }
                let label = NSTextField(labelWithString: title)
                label.font = isHeader ? .systemFont(ofSize: 11, weight: .semibold) : .menuFont(ofSize: 0)
                label.textColor = isHeader ? .secondaryLabelColor : item.isEnabled ? .labelColor : .disabledControlTextColor
                let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: isHeader ? 20 : 24))
                label.frame = NSRect(x: 14, y: isHeader ? 2 : 4, width: width - 28, height: 16)
                row.addSubview(label)
                rows.append(row)
            }
        }
        let height = rows.reduce(10) { $0 + $1.frame.height }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        window.contentView = container
        var y = height - 5
        for row in rows {
            y -= row.frame.height
            row.frame.origin = NSPoint(x: 0, y: y)
            container.addSubview(row)
        }
        container.layoutSubtreeIfNeeded()
        container.displayIfNeeded()
        var data: Data?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds)!
            container.cacheDisplay(in: container.bounds, to: bitmap)
            data = bitmap.representation(using: .png, properties: [:])
        }
        rows.forEach { $0.subviews.forEach { ($0 as? NSTextField) == nil && $0.superview?.subviews.count == 1 ? $0.removeFromSuperview() : () }; $0.removeFromSuperview() }
        return try XCTUnwrap(data)
    }
}
