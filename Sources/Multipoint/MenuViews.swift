import AppKit
import HeadphoneKit
import MDRKit

/// Views for menu items that respond in place instead of closing the menu: device rows that show a switch in
/// progress, switches, and the noise control. AppKit sizes each to the menu's width.
enum MenuMetrics {
    static let width: CGFloat = 330
    static let rowHeight: CGFloat = 24
    /// Where standard menu items start their titles.
    static let inset: CGFloat = 14
}

/// A row with an optional icon, a title, and a trailing detail, checkmark, spinner or switch.
final class MenuRowView: NSView {
    enum Accessory: Equatable {
        case none
        case check
        case spinner
        case toggle(Bool)
    }

    var onClick: (() -> Void)?
    /// ⌥-click, when set; the row shows `alternateTitle` while ⌥ is held.
    var onOptionClick: (() -> Void)?

    private let highlight = NSVisualEffectView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let checkView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let toggle = NSSwitch()
    private let stack = NSStackView()

    private var title = ""
    private var alternateTitle: String?
    private var accessory = Accessory.none
    private var isEnabled = true
    private var isHovering = false
    private var flagsMonitor: Any?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: MenuMetrics.rowHeight))
        autoresizingMask = [.width]

        highlight.material = .selection
        highlight.state = .active
        highlight.isEmphasized = true
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 5
        highlight.isHidden = true
        highlight.frame = bounds.insetBy(dx: 5, dy: 0)
        highlight.autoresizingMask = [.width, .height]
        addSubview(highlight)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .menuFont(ofSize: 0)
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        checkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = #selector(toggled)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: MenuMetrics.inset, bottom: 0, right: MenuMetrics.inset)
        stack.distribution = .fill
        for view in [iconView, titleLabel, spacer, detailLabel, checkView, spinner, toggle] { stack.addArrangedSubview(view) }
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)

        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(symbol: String? = nil, title: String, alternateTitle: String? = nil, detail: String? = nil,
                   accessory: Accessory = .none, enabled: Bool = true, toolTip: String? = nil) {
        self.title = title
        self.alternateTitle = alternateTitle
        self.accessory = accessory
        isEnabled = enabled
        self.toolTip = toolTip
        iconView.isHidden = symbol == nil
        if let symbol {
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
        checkView.isHidden = accessory != .check
        spinner.isHidden = accessory != .spinner
        if accessory == .spinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        if case let .toggle(on) = accessory {
            toggle.isHidden = false
            toggle.state = on ? .on : .off
            toggle.isEnabled = enabled
        } else {
            toggle.isHidden = true
        }
        setAccessibilityLabel(title)
        refreshAppearance()
    }

    /// Switch rows keep still under the pointer, like the ones in the system's own menus.
    private var highlights: Bool {
        if case .toggle = accessory { return false }
        return isEnabled && isHovering && (onClick != nil || onOptionClick != nil)
    }

    private func refreshAppearance() {
        let optionHeld = NSEvent.modifierFlags.contains(.option) && isHovering && onOptionClick != nil
        titleLabel.stringValue = optionHeld ? alternateTitle ?? title : title
        highlight.isHidden = !highlights
        let primary: NSColor = !isEnabled ? .disabledControlTextColor : highlights ? .selectedMenuItemTextColor : .labelColor
        let secondary: NSColor = highlights ? .selectedMenuItemTextColor : .secondaryLabelColor
        titleLabel.textColor = primary
        detailLabel.textColor = secondary
        iconView.contentTintColor = primary
        checkView.contentTintColor = primary
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        if onOptionClick != nil, flagsMonitor == nil {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.refreshAppearance()
                return event
            }
        }
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        stopHovering()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopHovering() } // the menu closed with the pointer still over the row
    }

    private func stopHovering() {
        isHovering = false
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        refreshAppearance()
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate(option: event.modifierFlags.contains(.option))
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        activate(option: false)
        return true
    }

    @objc private func toggled() { onClick?() }

    private func activate(option: Bool) {
        if option, let onOptionClick { onOptionClick() } else { onClick?() }
    }
}

/// The headphones' name, with a spinner while connecting to them.
final class MenuHeaderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 26))
        autoresizingMask = [.width]
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [titleLabel, spacer, statusLabel, spinner])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: MenuMetrics.inset, bottom: 0, right: MenuMetrics.inset)
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(title: String, status: String?, busy: Bool) {
        titleLabel.stringValue = title
        statusLabel.stringValue = status ?? ""
        statusLabel.isHidden = status == nil
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}

/// Noise Cancelling / Ambient Sound / Off as three round buttons, the way Control Center shows them for headphones.
final class NoiseModesView: NSView {
    var onSelect: ((NoiseControlMode) -> Void)?
    private var buttons: [NoiseControlMode: ModeButton] = [:]
    private let stack = NSStackView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 62))
        autoresizingMask = [.width]
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 2, left: MenuMetrics.inset - 4, bottom: 2, right: MenuMetrics.inset - 4)
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(modes: [NoiseControlMode], selected: NoiseControlMode?, enabled: Bool) {
        if stack.arrangedSubviews.count != modes.count || modes.contains(where: { buttons[$0] == nil }) {
            stack.setViews([], in: .leading)
            buttons.removeAll()
            for mode in modes {
                let button = ModeButton(mode: mode)
                button.onClick = { [weak self] in self?.onSelect?(mode) }
                buttons[mode] = button
                stack.addArrangedSubview(button)
            }
        }
        for (mode, button) in buttons {
            button.isSelected = mode == selected
            button.isEnabled = enabled
        }
    }

    final class ModeButton: NSView {
        let mode: NoiseControlMode
        var onClick: (() -> Void)?
        var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
        var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }
        private var isHovering = false { didSet { needsDisplay = true } }
        private var isPressed = false { didSet { needsDisplay = true } }

        init(mode: NoiseControlMode) {
            self.mode = mode
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(mode.title)
            toolTip = mode.title
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func draw(_ dirtyRect: NSRect) {
            let diameter: CGFloat = 34
            let circle = NSRect(x: bounds.midX - diameter / 2, y: bounds.maxY - diameter - 2, width: diameter, height: diameter)
            let fill: NSColor
            if isSelected {
                fill = .controlAccentColor
            } else {
                fill = .labelColor.withAlphaComponent(isPressed ? 0.22 : isHovering && isEnabled ? 0.16 : 0.1)
            }
            fill.withAlphaComponent(fill.alphaComponent * (isEnabled ? 1 : 0.5)).setFill()
            NSBezierPath(ovalIn: circle).fill()

            let tint: NSColor = isSelected ? .white : isEnabled ? .labelColor : .disabledControlTextColor
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
                .applying(.init(paletteColors: [tint]))
            if let image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let size = image.size
                image.draw(in: NSRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2,
                                      width: size.width, height: size.height))
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let label = NSAttributedString(string: mode.shortTitle, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: isSelected ? .medium : .regular),
                .foregroundColor: isEnabled ? (isSelected ? NSColor.labelColor : .secondaryLabelColor) : .disabledControlTextColor,
                .paragraphStyle: paragraph,
            ])
            label.draw(in: NSRect(x: 0, y: bounds.minY + 2, width: bounds.width, height: 14))
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { isHovering = true }
        override func mouseExited(with event: NSEvent) { isHovering = false; isPressed = false }
        override func mouseDown(with event: NSEvent) { isPressed = isEnabled }

        override func mouseUp(with event: NSEvent) {
            let wasPressed = isPressed
            isPressed = false
            // A menu opened by press-and-drag delivers only the mouse-up.
            guard isEnabled, wasPressed || bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            onClick?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { isHovering = false; isPressed = false }
        }

        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }
            onClick?()
            return true
        }

        override func accessibilityValue() -> Any? { isSelected ? 1 : 0 }
    }
}

/// How much outside sound ambient mode lets in.
final class AmbientLevelView: NSView {
    /// `adjusting` is true while the slider is still being dragged.
    var onChange: ((_ level: UInt8, _ adjusting: Bool) -> Void)?
    private(set) var isDragging = false

    private let slider = NSSlider()
    private let lessIcon = NSImageView()
    private let moreIcon = NSImageView()
    private let valueLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 28))
        autoresizingMask = [.width]
        let levels = NoiseControl.ambientLevels
        slider.minValue = Double(levels.lowerBound)
        slider.maxValue = Double(levels.upperBound)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(moved)
        slider.setAccessibilityLabel("Ambient sound level")

        for (icon, symbol, label) in [(lessIcon, "ear", "Less"), (moreIcon, "ear.and.waveform", "More")] {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            icon.contentTintColor = .secondaryLabelColor
            icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        }
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        [lessIcon, slider, moreIcon, valueLabel].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let inset = MenuMetrics.inset, icon: CGFloat = 18, value: CGFloat = 20, gap: CGFloat = 6
        let middle = bounds.midY
        lessIcon.frame = NSRect(x: inset, y: middle - 9, width: icon, height: 18)
        valueLabel.frame = NSRect(x: bounds.maxX - inset - value, y: middle - 8, width: value, height: 16)
        moreIcon.frame = NSRect(x: valueLabel.frame.minX - gap - icon, y: middle - 9, width: icon, height: 18)
        let left = lessIcon.frame.maxX + gap
        slider.frame = NSRect(x: left, y: middle - 10, width: moreIcon.frame.minX - gap - left, height: 20)
    }

    func configure(level: UInt8, enabled: Bool) {
        slider.isEnabled = enabled
        guard !isDragging else { return } // don't pull the knob out from under the pointer
        slider.integerValue = Int(level)
        valueLabel.stringValue = "\(level)"
    }

    @objc private func moved() {
        let level = UInt8(clamping: Int(slider.doubleValue.rounded()))
        // A continuous slider sends its last action on mouse-up.
        let ended = NSApp.currentEvent?.type == .leftMouseUp
        isDragging = !ended
        valueLabel.stringValue = "\(level)"
        onChange?(level, !ended)
    }
}

/// One band of the equalizer: what it is, a slider, and its level.
final class BandSliderView: NSView {
    /// `adjusting` is true while the slider is still being dragged.
    var onChange: ((_ level: Int, _ adjusting: Bool) -> Void)?
    private(set) var isDragging = false

    private let nameLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 22))
        autoresizingMask = [.width]
        nameLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.alignment = .right
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(moved)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.alignment = .right
        [nameLabel, slider, valueLabel].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let inset = MenuMetrics.inset, name: CGFloat = 34, value: CGFloat = 24, gap: CGFloat = 8
        let middle = bounds.midY
        nameLabel.frame = NSRect(x: inset, y: middle - 8, width: name, height: 16)
        valueLabel.frame = NSRect(x: bounds.maxX - inset - value, y: middle - 8, width: value, height: 16)
        let left = nameLabel.frame.maxX + gap
        slider.frame = NSRect(x: left, y: middle - 10, width: valueLabel.frame.minX - gap - left, height: 20)
    }

    func configure(name: String, level: Int, range: ClosedRange<Int>, enabled: Bool) {
        nameLabel.stringValue = name
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.numberOfTickMarks = range.count
        slider.allowsTickMarkValuesOnly = true
        slider.isEnabled = enabled
        slider.setAccessibilityLabel("\(name) band")
        guard !isDragging else { return } // don't pull the knob out from under the pointer
        slider.integerValue = level
        show(level, enabled: enabled)
    }

    private func show(_ level: Int, enabled: Bool) {
        valueLabel.stringValue = level > 0 ? "+\(level)" : "\(level)"
        valueLabel.textColor = !enabled ? .disabledControlTextColor : level == 0 ? .secondaryLabelColor : .labelColor
    }

    @objc private func moved() {
        let level = Int(slider.doubleValue.rounded())
        // A continuous slider sends its last action on mouse-up.
        let ended = NSApp.currentEvent?.type == .leftMouseUp
        isDragging = !ended
        show(level, enabled: true)
        onChange?(level, !ended)
    }
}
