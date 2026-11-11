import AppKit

/// The About window: the headphones on the dark backdrop, and how to use the app in a few lines.
@MainActor
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() {
        let content = AboutView(photo: AboutView.bundledPhoto)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: content.fittingSize),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "About Multipoint"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.contentView = content
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        // A menu bar app isn't in front by default, so step forward for the window.
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }
}

final class AboutView: NSView {
    static let width: CGFloat = 460
    static let repository = URL(string: "https://github.com/pkhr/multipoint-switcher")!

    /// The picture of the headphones, which the build script copies into the app.
    static var bundledPhoto: NSImage? {
        Bundle.main.url(forResource: "Headphones", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }

    private static let steps: [(symbol: String, title: String, text: String)] = [
        ("headphones", "Open the menu", "Click the headphones in the menu bar. The menu stays open while you change things."),
        ("person.wave.2.fill", "Shape the sound", "Noise Cancelling, Ambient Sound or Off at the top; presets and bands under Equalizer."),
        ("laptopcomputer.and.iphone", "Choose the source", "Click a device under Audio Source to play from it. ⌥-click disconnects it."),
        ("command", "Switch from anywhere", "⌃⌥⌘B moves the sound to the other connected device."),
        ("mic", "Keep full quality", "Mac Microphone keeps the Mac off the headphones' mic, which would mean call-quality sound."),
        ("dot.radiowaves.left.and.right", "Shares the headphones", "It connects only while it has something to do, so Sony's app and your other devices can still reach them."),
    ]

    init(photo: NSImage?) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 700))
        appearance = NSAppearance(named: .darkAqua)

        let photoView = NSImageView()
        photoView.image = photo
        photoView.imageScaling = .scaleProportionallyUpOrDown
        photoView.heightAnchor.constraint(equalToConstant: photo == nil ? 24 : 185).isActive = true

        let title = label("Multipoint", size: 28, weight: .bold)
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String).map { "VERSION \($0)" } ?? "FOR SONY HEADPHONES"
        let versionLabel = label(version, size: 11, weight: .semibold, color: .white.withAlphaComponent(0.55), tracking: 1.6)
        let tagline = label("Noise control, equalizer and audio source for Sony headphones, from the menu bar.",
                            size: 13, color: .white.withAlphaComponent(0.72), alignment: .center)

        let header = NSStackView(views: [photoView, title, versionLabel, tagline])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 6
        header.setCustomSpacing(14, after: photoView)
        header.setCustomSpacing(12, after: versionLabel)

        let howTo = label("HOW TO USE IT", size: 11, weight: .semibold, color: .white.withAlphaComponent(0.55), tracking: 1.6)
        let card = NSStackView(views: Self.steps.map(row))
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 11
        card.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0.085, alpha: 1).cgColor
        card.layer?.cornerRadius = 18
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor

        let link = NSButton(title: "Source and updates on GitHub", target: self, action: #selector(openRepository))
        link.isBordered = false
        link.attributedTitle = NSAttributedString(string: link.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        let disclaimer = label("Not affiliated with Sony.", size: 11, color: .white.withAlphaComponent(0.4))
        let footer = NSStackView(views: [link, disclaimer])
        footer.orientation = .vertical
        footer.alignment = .centerX
        footer.spacing = 4

        let stack = NSStackView(views: [header, howTo, card, footer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: header)
        stack.setCustomSpacing(14, after: card)
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 24, bottom: 18, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let inner = Self.width - 48
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
            header.widthAnchor.constraint(equalToConstant: inner), card.widthAnchor.constraint(equalToConstant: inner),
            howTo.widthAnchor.constraint(equalToConstant: inner - 8),
            tagline.widthAnchor.constraint(lessThanOrEqualToConstant: inner - 40),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The backdrop: dark grey falling to black, with a pool of light behind the headphones.
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let colors = [CGColor(gray: 0.21, alpha: 1), CGColor(gray: 0.07, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray
        let backdrop = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 0.5, 0.85])!
        context.drawLinearGradient(backdrop, start: CGPoint(x: 0, y: bounds.maxY), end: CGPoint(x: 0, y: bounds.minY),
                                   options: [.drawsAfterEndLocation])
        let glow = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 0.17), CGColor(gray: 1, alpha: 0.05),
                                                         CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 0.55, 1])!
        let centre = CGPoint(x: bounds.midX, y: bounds.maxY - 125)
        context.drawRadialGradient(glow, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 170, options: [])
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white,
                       tracking: CGFloat = 0, alignment: NSTextAlignment = .natural) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        field.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: tracking, .paragraphStyle: style,
        ])
        field.isSelectable = false
        return field
    }

    /// A symbol, then a bold lead-in and what it means.
    private func row(_ step: (symbol: String, title: String, text: String)) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: step.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        icon.contentTintColor = .white
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let text = NSMutableAttributedString(string: step.title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        text.append(NSAttributedString(string: step.text, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.62),
        ]))
        let body = NSTextField(wrappingLabelWithString: "")
        body.attributedStringValue = text
        body.isSelectable = false
        body.widthAnchor.constraint(equalToConstant: Self.width - 48 - 32 - 26 - 10).isActive = true

        let row = NSStackView(views: [icon, body])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        return row
    }

    @objc private func openRepository() {
        NSWorkspace.shared.open(Self.repository)
    }
}
