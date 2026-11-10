import Foundation
import MDRKit

/// The headphones as an app sees them: the last known status, and actions that connect only for as long as they take.
///
/// Nothing stays connected in the background. An action (or `hold()`, while a UI is on screen) opens the control
/// channel, and it's closed again shortly after the last command finishes, so Sound Connect, the command-line tool
/// and the app on your other devices can all reach the headphones.
@MainActor
public final class HeadphoneController {
    public enum Link: Equatable {
        /// Not connected, by design: nothing to do.
        case idle
        case connecting
        case live
        /// The last attempt to connect failed; the text says why.
        case failed(String)
    }

    public private(set) var link: Link = .idle
    public private(set) var status: HeadphoneStatus
    public private(set) var capabilities: HeadphoneCapabilities?
    /// When the device list was last read from the headphones.
    public private(set) var lastSync: Date?
    /// Addresses of devices with a switch, connect or disconnect in progress.
    public private(set) var busyDevices: Set<String> = []

    /// Called after any change to the properties above.
    public var onChange: (() -> Void)?
    /// User-facing problems, e.g. "Can't switch during a call".
    public var onNotice: ((String) -> Void)?
    public var log: ((String) -> Void)?
    /// How long the channel stays open after the last command, in case another follows.
    public var linger: Duration = .milliseconds(1500)

    private let makeTransport: () -> HeadphoneTransport?
    private var session: HeadphoneSession?
    private var holds = 0
    private var waiting: [(HeadphoneSession?) -> Void] = []
    private var closeTask: Task<Void, Never>?
    private var lastFailure: String?

    /// - Parameter makeTransport: a fresh pipe to the headphones, or nil when they aren't reachable right now.
    public init(snapshot: HeadphoneSnapshot? = nil, makeTransport: @escaping () -> HeadphoneTransport?) {
        self.makeTransport = makeTransport
        status = snapshot?.status ?? HeadphoneStatus()
        capabilities = snapshot?.capabilities
        lastSync = snapshot?.date
    }

    public var snapshot: HeadphoneSnapshot {
        HeadphoneSnapshot(capabilities: capabilities, status: status, date: lastSync)
    }

    // MARK: Connection

    /// Keeps the channel open until the matching `release()`, for while a UI is showing live state.
    public func hold() {
        holds += 1
        closeTask?.cancel()
        sync()
    }

    public func release() {
        holds = max(0, holds - 1)
        scheduleClose()
    }

    /// Reads fresh state from the headphones, connecting if needed. The completion gets nil on success.
    public func sync(_ scope: HeadphoneSession.Scope = .all, completion: ((String?) -> Void)? = nil) {
        withSession { [weak self] session in
            guard let self, let session else { completion?(self?.lastFailure ?? "Not connected"); return }
            session.load(scope) { [weak self] ok in
                if ok, scope.contains(.devices) { self?.lastSync = Date() }
                self?.changed()
                completion?(ok ? nil : "The headphones didn't answer")
            }
        }
    }

    /// Drops the channel now and forgets what's known, e.g. when the headphones disconnect or others are chosen.
    public func reset(keepingStatus: Bool = false) {
        closeSession()
        link = .idle
        if !keepingStatus {
            status = HeadphoneStatus()
            capabilities = nil
            lastSync = nil
        }
        changed()
    }

    /// Hands `work` a ready session, opening one first if needed, or nil if the headphones can't be reached.
    private func withSession(_ work: @escaping (HeadphoneSession?) -> Void) {
        closeTask?.cancel()
        if let session, session.state == .ready {
            work(session)
            scheduleClose()
            return
        }
        waiting.append(work)
        if session == nil { openSession() }
    }

    private func openSession() {
        guard let transport = makeTransport() else {
            finishOpening(nil, failure: "The headphones aren't connected to this device")
            return
        }
        let newSession = HeadphoneSession(transport: transport, capabilities: capabilities, status: status)
        newSession.log = log
        newSession.onNotice = { [weak self] in self?.onNotice?($0) }
        newSession.onIdle = { [weak self] in self?.scheduleClose() }
        newSession.onChange = { [weak self, weak newSession] in
            guard let self, let newSession, newSession === self.session else { return }
            self.sessionChanged(newSession)
        }
        session = newSession
        link = .connecting
        changed()
        newSession.start()
    }

    private func sessionChanged(_ session: HeadphoneSession) {
        switch session.state {
        case .connecting:
            break
        case .ready:
            capabilities = session.capabilities
            status = session.status
            if link != .live {
                link = .live
                lastFailure = nil
                finishOpening(session, failure: nil)
            }
            changed()
        case let .closed(reason):
            self.session = nil
            busyDevices = []
            if waiting.isEmpty {
                link = .idle // it dropped while we weren't asking for anything; the next action reconnects
                changed()
            } else {
                finishOpening(nil, failure: reason ?? "The connection to the headphones closed")
            }
        }
    }

    private func finishOpening(_ session: HeadphoneSession?, failure: String?) {
        if let failure {
            lastFailure = failure
            link = .failed(failure)
        }
        let work = waiting
        waiting.removeAll()
        work.forEach { $0(session) }
        changed()
        scheduleClose()
    }

    private func scheduleClose() {
        closeTask?.cancel()
        guard holds == 0, let session, session.state == .ready, !session.isBusy else { return }
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: self?.linger ?? .zero)
            guard !Task.isCancelled, let self, self.holds == 0, self.session?.isBusy == false else { return }
            self.log?("idle, closing the channel")
            self.closeSession()
            self.link = .idle
            self.changed()
        }
    }

    private func closeSession() {
        closeTask?.cancel()
        let closing = session
        session = nil
        closing?.onChange = nil
        closing?.onIdle = nil
        closing?.stop()
        busyDevices = []
        let work = waiting
        waiting.removeAll()
        work.forEach { $0(nil) }
    }

    private func changed() { onChange?() }

    // MARK: Devices

    /// Makes a connected device the audio source. The completion gets nil on success, else a user-facing reason.
    public func switchPlayback(to target: PairedDevice, completion: ((String?) -> Void)? = nil) {
        deviceAction(target, completion: completion) { session, done in session.switchPlayback(to: target, completion: done) }
    }

    /// Switches to the connected device after the one that's playing, going by the last known device list.
    /// Returns that device, or nil if there's no other.
    @discardableResult
    public func switchToNextDevice(completion: ((String?) -> Void)? = nil) -> PairedDevice? {
        guard let target = status.nextDevice else {
            completion?("Only one device is connected to the headphones")
            return nil
        }
        switchPlayback(to: target, completion: completion)
        return target
    }

    public func connect(_ target: PairedDevice, completion: ((String?) -> Void)? = nil) {
        deviceAction(target, completion: completion) { session, done in session.connect(target, completion: done) }
    }

    public func disconnect(_ target: PairedDevice, completion: ((String?) -> Void)? = nil) {
        deviceAction(target, completion: completion) { session, done in session.disconnect(target, completion: done) }
    }

    private func deviceAction(_ target: PairedDevice, completion: ((String?) -> Void)?,
                              _ action: @escaping (HeadphoneSession, @escaping (String?) -> Void) -> Void) {
        busyDevices.insert(target.address)
        changed()
        let finish: (String?) -> Void = { [weak self] failure in
            guard let self else { return }
            self.busyDevices.remove(target.address)
            if let failure { self.onNotice?(failure) }
            self.changed()
            completion?(failure)
        }
        withSession { [weak self] session in
            guard let session else { return finish(self?.lastFailure ?? "Not connected") }
            action(session, finish)
        }
    }

    // MARK: Settings

    public func setAutoSwitch(_ enabled: Bool) {
        change({ $0.autoSwitch = enabled }) { $0.setAutoSwitch(enabled) }
    }

    /// - Parameter adjusting: true while a slider is being dragged; call once more with false when it's released.
    public func setNoiseControl(_ value: NoiseControl, adjusting: Bool = false) {
        change({ $0.noiseControl = value }) { $0.setNoiseControl(value, adjusting: adjusting) }
    }

    public func setNoiseMode(_ mode: NoiseControlMode) {
        guard var value = status.noiseControl else { return }
        value.mode = mode
        setNoiseControl(value)
    }

    public func setSidetone(_ on: Bool) {
        change({ $0.sidetone = on }) { $0.setSidetone(on) }
    }

    public func setSpeakToChat(_ on: Bool) {
        change({ $0.speakToChat = on }) { $0.setSpeakToChat(on) }
    }

    public func setSpeakToChatDetail(_ detail: SpeakToChatDetail) {
        change({ $0.speakToChatDetail = detail }) { $0.setSpeakToChatDetail(detail) }
    }

    public func setMicMute(_ settings: MicMuteSettings) {
        change({ $0.micMute = settings }) { $0.setMicMute(settings) }
    }

    // MARK: Equalizer

    public func selectEqualizerPreset(_ id: UInt8) {
        change({ $0.equalizer = Equalizer(presetID: id, steps: $0.equalizer?.steps ?? []) }) { $0.selectEqualizerPreset(id) }
    }

    /// Moves one band. Only custom presets can be changed, so from any other preset this starts a custom one from
    /// the bands as they are.
    /// - Parameter adjusting: true while a slider is being dragged; call once more with false when it's released.
    public func setEqualizerLevel(_ level: Int, band: Int, adjusting: Bool = false) {
        guard let info = capabilities?.equalizer, info.isCustomizable, var value = status.equalizer,
              value.steps.indices.contains(band) else { return }
        if info.preset(value.presetID)?.isCustom != true {
            guard let custom = info.customPreset else { return }
            value.presetID = custom.id
        }
        value.setLevel(level, band: band, in: info)
        change({ $0.equalizer = value }) { $0.setEqualizer(value, adjusting: adjusting) }
    }

    /// Shows the new value right away, sends it, and lets the headphones' read-back confirm or correct it.
    private func change(_ optimistic: (inout HeadphoneStatus) -> Void, _ send: @escaping (HeadphoneSession) -> Void) {
        let before = status
        optimistic(&status)
        session?.status = status
        changed()
        withSession { [weak self] session in
            guard let self else { return }
            guard let session else {
                self.status = before
                self.onNotice?(self.lastFailure ?? "Not connected")
                self.changed()
                return
            }
            send(session)
        }
    }

    /// Sends a raw request and hands back the reply, for protocol exploration.
    public func query(table: UInt8, _ payload: [UInt8], completion: @escaping ([UInt8]?) -> Void) {
        withSession { session in
            guard let session else { return completion(nil) }
            session.query(table: table, payload, completion: completion)
        }
    }
}
