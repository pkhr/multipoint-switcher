import AppKit
import Carbon.HIToolbox
import HeadphoneKit
import IOBluetooth
import MDRKit
import ServiceManagement

/// The menu bar app: one status item whose menu shows the headphones' noise control and connected devices, live.
///
/// It doesn't stay connected to the headphones. The control channel is opened when the menu opens, when the
/// shortcut is pressed, and for a moment when something suggests the audio source may have changed; it's closed as
/// soon as that's done. In between the app does nothing at all.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let headphonesDefaultsKey = "headphonesAddress"

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private lazy var renderer = MenuRenderer(menu: menu)
    var menuForTesting: NSMenu { menu }
    private var headphones: IOBluetoothDevice?
    private var controller: HeadphoneController?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?
    private var hotKey: HotKey?
    private var notice: (text: String, date: Date)?
    private var menuIsOpen = false
    private var menuTimer: Timer?
    private var watchTimer: Timer?
    private var refreshPending = false
    private var macConnectInProgress = false
    private var lastSwitch = Date.distantPast
    private var lastSourceCheck = Date.distantPast
    private var iconFlash: Task<Void, Never>?
    private let audioRouter = AudioRouter()
    private let micRouter = MicrophoneRouter()
    private var hostAddress = HeadphoneDirectory.hostAddress
    private let debug = ProcessInfo.processInfo.environment["MULTIPOINT_DEBUG"] != nil
    /// Simulated headphones, for trying the menu without real ones: `MULTIPOINT_DEMO=1`.
    private let demo = ProcessInfo.processInfo.environment["MULTIPOINT_DEMO"].map { _ in SimulatedHeadphones.Memory() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        statusItem.menu = menu

        hotKey = HotKey(keyCode: kVK_ANSI_B, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.switchToOtherDevice()
        }
        if let demo {
            hostAddress = normalizeAddress(String(decoding: SimulatedHeadphones.mac, as: UTF8.self))
            controller = makeController { SimulatedHeadphones(memory: demo) }
            refreshUI()
            return
        }

        BluetoothLink.warmUp()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(bluetoothDeviceConnected(_:device:)))
        select(HeadphoneDirectory.preferred(rememberedAddress: UserDefaults.standard.string(forKey: Self.headphonesDefaultsKey)))
        audioRouter.onOutputActivity = { [weak self] in self?.outputActivity() }
        audioRouter.startObservingOutputChanges()
        if debug { micRouter.log = { NSLog("[Multipoint] %@", $0) } }
        micRouter.start()
    }

    // MARK: Headphones

    private var headphonesName: String { demo != nil ? "1000X The ColleXion (Demo)" : headphones?.name ?? "Headphones" }
    private var headphonesConnected: Bool { demo != nil || headphones?.isConnected() == true }

    private func select(_ device: IOBluetoothDevice?) {
        stopLiveUpdates()
        controller?.reset()
        controller = nil
        disconnectNotification?.unregister()
        disconnectNotification = nil
        headphones = device
        audioRouter.headphonesAddress = device.map(\.normalizedAddress)
        micRouter.headphonesAddress = audioRouter.headphonesAddress
        audioRouter.resetTracking()
        if let device {
            controller = makeController { [weak device] in
                guard let device, device.isConnected() else { return nil }
                return BluetoothLink(device: device)
            }
            headphonesDidConnect()
        }
        refreshUI()
    }

    private func makeController(_ transport: @escaping () -> HeadphoneTransport?) -> HeadphoneController {
        let controller = HeadphoneController(makeTransport: transport)
        controller.onChange = { [weak self] in self?.controllerChanged() }
        controller.onNotice = { [weak self] in self?.show(notice: $0) }
        if debug { controller.log = { NSLog("[Multipoint] %@", $0) } }
        return controller
    }

    /// Looks for headphones paired since launch.
    private func findHeadphonesIfNeeded() {
        guard headphones == nil, demo == nil else { return }
        let remembered = UserDefaults.standard.string(forKey: Self.headphonesDefaultsKey)
        if let found = HeadphoneDirectory.preferred(rememberedAddress: remembered) { select(found) }
    }

    private func headphonesDidConnect() {
        guard let headphones, headphones.isConnected() else { return }
        if disconnectNotification == nil {
            disconnectNotification = headphones.register(forDisconnectNotification: self,
                                                         selector: #selector(bluetoothDeviceDisconnected(_:device:)))
        }
        audioRouter.resetTracking()
        if menuIsOpen {
            startLiveUpdates()
        } else {
            // One short look at who's playing, so Mac audio is routed right from the start.
            controller?.sync()
        }
    }

    // IOBluetooth may deliver these on its own queue rather than the main thread, so each one hops over first.

    @objc private nonisolated func bluetoothDeviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onMainActor { self.deviceConnected(device) }
    }

    private func deviceConnected(_ device: IOBluetoothDevice) {
        findHeadphonesIfNeeded()
        guard isHeadphones(device) else { return }
        // Let macOS bring up the audio profiles before opening the control channel.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.headphonesDidConnect()
            self?.refreshUI()
        }
    }

    @objc private nonisolated func bluetoothDeviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onMainActor { self.deviceDisconnected(note) }
    }

    private func deviceDisconnected(_ note: IOBluetoothUserNotification) {
        note.unregister()
        disconnectNotification = nil
        stopLiveUpdates()
        controller?.reset(keepingStatus: true)
        updateWatching()
        refreshUI()
    }

    private func isHeadphones(_ device: IOBluetoothDevice) -> Bool {
        guard let headphones else { return false }
        let address = device.normalizedAddress
        return !address.isEmpty && address == headphones.normalizedAddress
    }

    private func isThisMac(_ device: PairedDevice) -> Bool {
        device.normalizedAddress == hostAddress
    }

    private func controllerChanged() {
        if let controller, controller.link == .live { updateAudioRouting(controller.status) }
        updateWatching()
        refreshUI()
    }

    // MARK: Mac audio follows the source

    /// While another device has the headphones and they won't hand back on their own (auto-switch off), Mac audio
    /// sent to them is lost, so move it to another output; bring it back when the Mac is the source again.
    private func updateAudioRouting(_ status: HeadphoneStatus) {
        guard let hostAddress, status.devices.contains(where: { $0.normalizedAddress == hostAddress }) else { return }
        let macHasSource = status.devices.contains { $0.isPlaying && $0.normalizedAddress == hostAddress }
        let otherHasSource = status.devices.contains { $0.isPlaying && $0.normalizedAddress != hostAddress }
        let headphonesWontReturn = status.autoSwitch == false
        if debug {
            NSLog("[Multipoint] routing: macHasSource=%d otherHasSource=%d autoSwitch=%@ output=%@", macHasSource,
                  otherHasSource, String(describing: status.autoSwitch), AudioDevices.defaultDevice(.output)?.name ?? "?")
        }
        audioRouter.update(macShouldLeaveHeadphones: !macHasSource && otherHasSource && headphonesWontReturn)
    }

    /// The source can also be switched from the phone, and the headphones only tell whoever asked. Rather than
    /// staying connected to watch, look only when it matters: Mac audio is at stake and auto-switch is off.
    private var sourceMatters: Bool {
        guard headphonesConnected, let controller, controller.status.autoSwitch == false else { return false }
        return audioRouter.isDiverted || audioRouter.headphonesOutputIsRunning
    }

    /// The Mac started or stopped playing to the headphones, or the output changed.
    private func outputActivity() {
        updateWatching()
        guard sourceMatters, !menuIsOpen, Date().timeIntervalSince(lastSourceCheck) > 5 else { return }
        checkSource()
    }

    private func checkSource() {
        lastSourceCheck = Date()
        controller?.sync(.devices)
    }

    /// While Mac audio is at stake, re-check every 20 seconds; each check holds the channel for about a second.
    private func updateWatching() {
        let needed = sourceMatters && !menuIsOpen
        if needed, watchTimer == nil {
            let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkSource() }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            watchTimer = timer
        } else if !needed, let watchTimer {
            watchTimer.invalidate()
            self.watchTimer = nil
        }
    }

    // MARK: Switching

    func switchToOtherDevice() {
        // The in-menu shortcut and the global hot key can both fire for one key press.
        guard Date().timeIntervalSince(lastSwitch) > 0.5 else { return }
        guard let controller, headphonesConnected else { NSSound.beep(); return }
        lastSwitch = Date()
        // The list may have changed since it was last read (a switch made on the phone), so read it first.
        controller.sync(.devices) { [weak self] failure in
            guard let self, failure == nil, let target = controller.status.nextDevice else { NSSound.beep(); return }
            self.flashIcon(target.symbolName)
            self.play(from: target)
        }
    }

    private func play(from device: PairedDevice) {
        guard !device.isPlaying else { return }
        lastSwitch = Date()
        if isThisMac(device) { audioRouter.routeToHeadphones() }
        controller?.switchPlayback(to: device) { failure in
            if failure != nil { NSSound.beep() }
        }
    }

    // MARK: Mac ↔ headphones connection

    private func connectMac() {
        guard let headphones else { return }
        macConnectInProgress = true
        let result = headphones.openConnection(self)
        if result != kIOReturnSuccess {
            macConnectInProgress = false
            show(notice: String(format: "Couldn't connect (IOReturn 0x%08x)", result))
        }
        refreshUI()
    }

    @objc nonisolated func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        onMainActor { self.macConnectionFinished(succeeded: status == kIOReturnSuccess) }
    }

    private func macConnectionFinished(succeeded: Bool) {
        macConnectInProgress = false
        if !succeeded {
            show(notice: "Couldn't connect. Are the headphones on and in range?")
        }
        headphonesDidConnect()
        refreshUI()
    }

    private func disconnectMac() {
        stopLiveUpdates()
        controller?.reset(keepingStatus: true)
        _ = headphones?.closeConnection()
        refreshUI()
    }

    private func chooseHeadphones(_ address: String) {
        guard let device = HeadphoneDirectory.candidates().first(where: { $0.normalizedAddress == normalizeAddress(address) }) else { return }
        UserDefaults.standard.set(normalizeAddress(address), forKey: Self.headphonesDefaultsKey)
        select(device)
    }

    private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            show(notice: "Couldn't change the login item: \(error.localizedDescription)")
        }
    }

    // MARK: UI

    private func show(notice text: String) {
        notice = (text, Date())
        refreshUI()
    }

    /// Redraws on the next turn of the run loop, however many things changed in this one.
    private func refreshUI() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.updateStatusIcon()
            if self.menuIsOpen { self.renderer.render(self.menuEntries()) }
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        if iconFlash == nil { button.image = symbol("headphones") }
        button.appearsDisabled = !headphonesConnected
        if !headphonesConnected {
            button.toolTip = "Headphones not connected"
        } else if let playing = controller?.status.playingDevice {
            button.toolTip = "Last seen playing from \(playing.name)"
        } else {
            button.toolTip = headphonesName
        }
    }

    /// Briefly shows the new source's icon in the menu bar, as feedback for the global shortcut.
    private func flashIcon(_ symbolName: String) {
        iconFlash?.cancel()
        statusItem.button?.image = symbol(symbolName)
        iconFlash = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.iconFlash = nil
            self.updateStatusIcon()
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    // MARK: Menu lifecycle

    func menuNeedsUpdate(_ menu: NSMenu) {
        findHeadphonesIfNeeded()
        renderer.render(menuEntries())
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        updateWatching()
        startLiveUpdates()
    }

    /// Stays connected for as long as the menu is showing the headphones.
    private func startLiveUpdates() {
        guard menuIsOpen, menuTimer == nil, headphonesConnected, let controller else { return }
        controller.hold()
        // Other devices can switch the source or change a setting while the menu is open; keep it current.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.headphonesConnected else { return }
                self.controller?.sync(.devices)
                self.refreshUI() // also re-checks who's using the headphone mic
            }
        }
        RunLoop.main.add(timer, forMode: .common) // the menu runs the run loop in its own mode
        menuTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        stopLiveUpdates()
        updateWatching()
    }

    private func stopLiveUpdates() {
        guard let menuTimer else { return }
        menuTimer.invalidate()
        self.menuTimer = nil
        controller?.release()
    }

    // MARK: Menu contents

    private typealias Menu = MenuRenderer

    private func menuEntries() -> [MenuEntry] {
        var entries: [MenuEntry] = []
        guard headphones != nil || demo != nil else {
            entries.append(Menu.info("none", "No Sony headphones paired with this Mac"))
            return entries + footer()
        }
        let connecting = controller?.link == .connecting
        entries.append(Menu.view("header", MenuHeaderView.init) { [name = headphonesName, connected = headphonesConnected] view in
            view.configure(title: name, status: connected ? nil : "Not Connected", busy: connected && connecting)
        })

        if !headphonesConnected {
            entries.append(Menu.view("connect-mac", MenuRowView.init) { [weak self, busy = macConnectInProgress] row in
                row.configure(symbol: "laptopcomputer", title: busy ? "Connecting…" : "Connect This Mac",
                              accessory: busy ? .spinner : .none, enabled: !busy)
                row.onClick = { self?.connectMac() }
            })
        } else if let controller {
            if let warning = callQualityWarning() { entries.append(warning) }
            if case let .failed(reason) = controller.link {
                entries.append(Menu.info("failure", reason, symbol: "exclamationmark.triangle"))
                entries.append(Menu.view("retry", MenuRowView.init) { row in
                    row.configure(symbol: "arrow.clockwise", title: "Try Again")
                    row.onClick = { controller.sync() }
                })
            } else if controller.capabilities == nil {
                entries.append(Menu.info("reading", "Reading from the headphones…"))
            }
            entries += noiseControlSection(controller)
            if let equalizer = equalizerMenu(controller) { entries.append(equalizer) }
            entries += sourceSection(controller)
            entries.append(microphoneMenu(controller))
        }

        if let notice, Date().timeIntervalSince(notice.date) < 30 {
            entries.append(Menu.separator("sep.notice"))
            entries.append(Menu.info("notice", notice.text, symbol: "exclamationmark.triangle"))
        }
        return entries + footer()
    }

    private func noiseControlSection(_ controller: HeadphoneController) -> [MenuEntry] {
        guard let noise = controller.status.noiseControl else { return [] }
        var entries = [
            Menu.separator("sep.noise"),
            Menu.sectionHeader("noise.title", "Noise Control"),
            Menu.view("noise.modes", NoiseModesView.init) { view in
                view.configure(modes: noise.availableModes, selected: noise.mode, enabled: true)
                view.onSelect = { controller.setNoiseMode($0) }
            },
        ]
        guard noise.mode == .ambient else { return entries }
        let automatic = noise.adjustsAutomatically == true
        entries.append(Menu.view("noise.level", AmbientLevelView.init) { view in
            view.configure(level: noise.ambientLevel, enabled: !automatic)
            view.toolTip = automatic ? "The headphones are setting the level themselves." : "How much outside sound to let in."
            view.onChange = { level, adjusting in
                // Start from the latest state, which a notification may have changed during the drag.
                guard var value = controller.status.noiseControl else { return }
                value.ambientLevel = level
                controller.setNoiseControl(value, adjusting: adjusting)
            }
        })
        if noise.adjustsAutomatically != nil {
            entries.append(toggleRow("noise.auto", "Adjust Level Automatically", on: automatic,
                                     toolTip: "Lets in more or less outside sound depending on how loud it is around you.") {
                guard var value = controller.status.noiseControl else { return }
                value.adjustsAutomatically = !automatic
                controller.setNoiseControl(value)
            })
        }
        entries.append(toggleRow("noise.voice", "Focus on Voice", on: noise.focusOnVoice,
                                 toolTip: "Lets voices through while holding back other noise.") {
            guard var value = controller.status.noiseControl else { return }
            value.focusOnVoice.toggle()
            controller.setNoiseControl(value)
        })
        return entries
    }

    private func sourceSection(_ controller: HeadphoneController) -> [MenuEntry] {
        let status = controller.status
        guard !status.devices.isEmpty else { return [] }
        let connected = status.connectedDevices
        var entries = [Menu.separator("sep.source"), Menu.sectionHeader("source.title", "Audio Source")]
        for device in connected {
            let busy = controller.busyDevices.contains(device.address)
            let isMac = isThisMac(device)
            entries.append(Menu.view("source.\(device.address)", MenuRowView.init) { [weak self] row in
                row.configure(symbol: device.symbolName, title: device.name, alternateTitle: "Disconnect \(device.name)",
                              detail: isMac ? "This Mac" : nil,
                              accessory: busy ? .spinner : device.isPlaying ? .check : .none,
                              toolTip: "Click to play from this device. ⌥-click to disconnect it from the headphones.")
                row.onClick = { self?.play(from: device) }
                row.onOptionClick = { controller.disconnect(device) }
            })
        }
        let macHasSource = connected.contains { $0.isPlaying && isThisMac($0) }
        if !macHasSource, connected.contains(where: isThisMac),
           let output = AudioDevices.defaultDevice(.output), !audioRouter.isHeadphones(output) {
            entries.append(Menu.info("source.diverted", "Mac audio is playing on \(output.name)", symbol: "speaker.wave.2"))
        }

        let others = status.devices.filter { !$0.isConnected }
        if !others.isEmpty {
            entries.append(Menu.sectionHeader("others.title", "Connect Another Device"))
            for device in others {
                let busy = controller.busyDevices.contains(device.address)
                entries.append(Menu.view("other.\(device.address)", MenuRowView.init) { row in
                    row.configure(symbol: device.symbolName, title: device.name, accessory: busy ? .spinner : .none, enabled: !busy)
                    row.onClick = { controller.connect(device) }
                })
            }
        }

        entries.append(Menu.separator("sep.switching"))
        entries.append(Menu.command("switch-other", "Switch to Other Device", enabled: connected.count > 1,
                                    keyEquivalent: "b", modifiers: [.control, .option, .command]) { [weak self] in
            self?.switchToOtherDevice()
        })
        if controller.capabilities?.supportsAutoSwitch == true, let autoSwitch = status.autoSwitch {
            entries.append(toggleRow("auto-switch", "Auto-Switch When Another Device Plays", on: autoSwitch,
                                     toolTip: "When off, the headphones stay on the current source until you switch it here.") {
                controller.setAutoSwitch(!autoSwitch)
            })
        }
        entries.append(macAudioMenu())
        return entries
    }

    /// The equalizer: its presets, and a slider for each band.
    private func equalizerMenu(_ controller: HeadphoneController) -> MenuEntry? {
        guard let info = controller.capabilities?.equalizer, let value = controller.status.equalizer else { return nil }
        let available = controller.status.equalizerAvailable != false
        var entries: [MenuEntry] = []
        if !available {
            entries.append(Menu.info("unavailable", "The headphones won't change it right now", symbol: "exclamationmark.triangle"))
        }
        for preset in info.presets {
            entries.append(Menu.view("preset.\(preset.id)", MenuRowView.init) { row in
                row.configure(title: preset.title, accessory: preset.id == value.presetID ? .check : .none, enabled: available)
                row.onClick = { controller.selectEqualizerPreset(preset.id) }
            })
        }
        let levels = value.levels(in: info)
        if info.isCustomizable, !levels.isEmpty {
            entries.append(Menu.separator("sep.bands"))
            let labels = info.bandLabels
            for (band, level) in levels.enumerated() {
                entries.append(Menu.view("band.\(band)", BandSliderView.init) { view in
                    view.configure(name: band < labels.count ? labels[band] : "\(band + 1)", level: level, range: info.levels, enabled: available)
                    view.toolTip = info.preset(value.presetID)?.isCustom == true ? nil
                        : "Moving a band switches to \(info.customPreset?.title ?? "a custom preset"), starting from these levels."
                    view.onChange = { level, adjusting in controller.setEqualizerLevel(level, band: band, adjusting: adjusting) }
                })
            }
        }
        let title = "Equalizer: \(info.preset(value.presetID)?.title ?? EqualizerPreset(id: value.presetID).title)"
        return renderer.submenu("equalizer", title, entries)
    }

    private func toggleRow(_ key: String, _ title: String, on: Bool, enabled: Bool = true, toolTip: String? = nil,
                           _ action: @escaping () -> Void) -> MenuEntry {
        Menu.view(key, MenuRowView.init) { row in
            row.configure(title: title, accessory: .toggle(on), enabled: enabled, toolTip: toolTip)
            row.onClick = action
        }
    }

    /// While an app records from the headphones' mic, Bluetooth limits them to call-quality sound.
    private func callQualityWarning() -> MenuEntry? {
        guard demo == nil, let users = micRouter.headphoneMicUsers() else { return nil }
        let names = users.map(\.name)
        let who = names.isEmpty ? "An app is" : "\(ListFormatter.localizedString(byJoining: names)) \(names.count == 1 ? "is" : "are")"
        let app = users.compactMap(\.appURL).first
        return Menu.command("mic-warning", "Call-quality sound: \(who) using the headphone mic",
                            symbol: "exclamationmark.triangle", enabled: app != nil,
                            toolTip: "While an app records from the headphones' mic, Bluetooth limits them to 16 kHz mono in both "
                                + "directions. Choose another microphone in that app (click to open it) to get full-quality sound back.") {
            if let app { NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) }
        }
    }

    private func macAudioMenu() -> MenuEntry {
        let choice = audioRouter.choice
        var entries = [
            Menu.command("automatic", "Automatic\(audioRouter.automaticOutput.map { " (\($0.name))" } ?? "")",
                         checked: choice == .automatic) { [weak self] in self?.audioRouter.choice = .automatic },
            Menu.separator("sep.outputs"),
        ]
        for output in audioRouter.otherOutputs {
            entries.append(Menu.command("output.\(output.uid)", output.name, checked: choice == .output(uid: output.uid)) { [weak self] in
                self?.audioRouter.choice = .output(uid: output.uid)
            })
        }
        entries.append(Menu.separator("sep.stay"))
        entries.append(Menu.command("stay", "Leave on Headphones", checked: choice == .stayOnHeadphones) { [weak self] in
            self?.audioRouter.choice = .stayOnHeadphones
        })
        return renderer.submenu("mac-audio", "Mac Audio When Switched Away",
                                toolTip: "With Auto-Switch off, the headphones won't come back to this Mac on their own, so Mac "
                                    + "audio moves here instead of being lost. It moves back when you switch to the Mac.", entries)
    }

    private func microphoneMenu(_ controller: HeadphoneController) -> MenuEntry {
        let status = controller.status
        var entries: [MenuEntry] = []
        if demo == nil {
            let choice = micRouter.choice
            entries.append(Menu.sectionHeader("mac.title", "Mac Microphone"))
            entries.append(Menu.command("automatic", "Automatic\(micRouter.automaticInput.map { " (\($0.name))" } ?? "")",
                                        checked: choice == .automatic,
                                        toolTip: "Keeps the Mac's default microphone off the headphones, switching back whenever macOS picks them.") { [weak self] in
                self?.micRouter.choice = .automatic
            })
            for input in micRouter.otherInputs {
                entries.append(Menu.command("input.\(input.uid)", input.name, checked: choice == .input(uid: input.uid)) { [weak self] in
                    self?.micRouter.choice = .input(uid: input.uid)
                })
            }
            entries.append(Menu.command("headphones", "Headphones (Call-Quality Sound)", checked: choice == .headphones,
                                        toolTip: "While the headphones' mic is in use, Bluetooth limits their sound to 16 kHz mono.") { [weak self] in
                self?.micRouter.choice = .headphones
            })
        }

        if status.sidetone != nil || status.speakToChat != nil || status.micMute != nil {
            if !entries.isEmpty { entries.append(Menu.separator("sep.headphones")) }
            entries.append(Menu.sectionHeader("headphones.title", "Headphones"))
        }
        if let sidetone = status.sidetone {
            entries.append(toggleRow("sidetone", "Hear Your Voice on Calls", on: sidetone,
                                     toolTip: "Sidetone: plays your own voice in the headphones during calls, so you don't talk too loudly.") {
                controller.setSidetone(!sidetone)
            })
        }
        if let speakToChat = status.speakToChat {
            entries.append(toggleRow("speak-to-chat", "Speak-to-Chat", on: speakToChat,
                                     toolTip: "Pauses the music and lets in outside sound when you start talking.") {
                controller.setSpeakToChat(!speakToChat)
            })
            if let detail = status.speakToChatDetail {
                let microphone = renderer.child("microphone")
                let sensitivities: [(SpeakToChatSensitivity, String)] = [(.auto, "Auto"), (.high, "High"), (.low, "Low")]
                entries.append(microphone.submenu("sensitivity", "Speak-to-Chat Sensitivity", enabled: speakToChat,
                                                  sensitivities.map { option, label in
                    Menu.command(label, label, checked: option == detail.sensitivity) {
                        var changed = detail
                        changed.sensitivity = option
                        controller.setSpeakToChatDetail(changed)
                    }
                }))
                let timeouts: [(SpeakToChatTimeout, String)] = [(.short, "Short"), (.standard, "Standard"), (.long, "Long"),
                                                                (.never, "Don't Resume Automatically")]
                entries.append(microphone.submenu("resume", "Resume Music After Talking", enabled: speakToChat,
                                                  toolTip: "How long after you stop talking the music comes back.",
                                                  timeouts.map { option, label in
                    Menu.command(label, label, checked: option == detail.timeout) {
                        var changed = detail
                        changed.timeout = option
                        controller.setSpeakToChatDetail(changed)
                    }
                }))
            }
        }
        if let micMute = status.micMute {
            entries.append(toggleRow("mic-mute", "Mute Mic with Headphone Button", on: micMute.buttonMutes,
                                     toolTip: "Lets a button on the headphones mute and unmute the mic during calls.") {
                var changed = micMute
                changed.buttonMutes.toggle()
                controller.setMicMute(changed)
            })
            entries.append(toggleRow("mic-mute-sound", "Sound When Mic Is Muted", on: micMute.playsSound, enabled: micMute.buttonMutes) {
                var changed = micMute
                changed.playsSound.toggle()
                controller.setMicMute(changed)
            })
        }
        return renderer.submenu("microphone", "Microphone", entries)
    }

    private func footer() -> [MenuEntry] {
        var entries = [Menu.separator("sep.footer")]
        let candidates = demo == nil ? HeadphoneDirectory.candidates() : []
        if candidates.count > 1 {
            entries.append(renderer.submenu("headphones", "Headphones", candidates.map { candidate in
                Menu.command(candidate.normalizedAddress, candidate.name ?? candidate.normalizedAddress, checked: isHeadphones(candidate)) { [weak self] in
                    self?.chooseHeadphones(candidate.normalizedAddress)
                }
            }))
        }
        if demo == nil, headphonesConnected {
            entries.append(Menu.command("disconnect-mac", "Disconnect This Mac") { [weak self] in self?.disconnectMac() })
        }
        if Bundle.main.bundleURL.pathExtension == "app" {
            entries.append(Menu.command("login", "Open at Login", checked: SMAppService.mainApp.status == .enabled) { [weak self] in
                self?.toggleLoginItem()
            })
        }
        entries.append(Menu.separator("sep.quit"))
        entries.append(Menu.command("quit", "Quit Multipoint", keyEquivalent: "q") { NSApp.terminate(nil) })
        return entries
    }
}
