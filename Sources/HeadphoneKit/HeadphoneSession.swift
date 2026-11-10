import Foundation
import MDRKit

/// One open control connection: speaks the MDR v2 protocol over a transport.
///
/// The protocol is stop-and-wait: one command in flight, acknowledged with an ACK whose sequence number is
/// `1 - seq`; every data packet the headphones send must be ACKed the same way.
///
/// Sessions are meant to be short. `HeadphoneController` opens one when there's something to do and closes it once
/// `isBusy` turns false, so other apps and devices can reach the headphones in between.
@MainActor
public final class HeadphoneSession: HeadphoneTransportDelegate {
    public enum State: Equatable {
        case connecting
        case ready
        case closed(String?)
    }

    public struct Scope: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let devices = Scope(rawValue: 1)
        public static let noiseControl = Scope(rawValue: 2)
        /// Sidetone, Speak-to-Chat and mic mute.
        public static let settings = Scope(rawValue: 4)
        public static let equalizer = Scope(rawValue: 8)
        public static let all: Scope = [.devices, .noiseControl, .settings, .equalizer]
    }

    public private(set) var state: State = .connecting
    /// Nil until the handshake finishes, unless supplied up front.
    public private(set) var capabilities: HeadphoneCapabilities?
    public var status: HeadphoneStatus {
        didSet { if status != oldValue { onChange?() } }
    }

    /// Called after any change to `state` or `status`.
    public var onChange: (() -> Void)?
    /// Called when the last queued command and follow-up check has finished.
    public var onIdle: (() -> Void)?
    /// User-facing problems reported by the headphones.
    public var onNotice: ((String) -> Void)?
    /// Raw traffic, for debugging.
    public var log: ((String) -> Void)?

    private let transport: HeadphoneTransport
    private var decoder = MDRStreamDecoder()
    private var sequence: UInt8 = 0
    private var queue: [Request] = []
    private var inFlight: Request?
    private var timeout: Task<Void, Never>?
    private var followUps: [UUID: (task: Task<Void, Never>, onCancel: (() -> Void)?)] = [:]
    private var protocolInfo: ProtocolInfo?
    private var discovered = HeadphoneCapabilities()
    /// Settings with a write that hasn't been acknowledged yet. Values the headphones report meanwhile are older
    /// than what the user just chose, so they're ignored instead of making the UI jump back.
    private var writing: [Setting: Int] = [:]

    private enum Setting: Hashable {
        case autoSwitch, noiseControl, sidetone, speakToChat, speakToChatDetail, micMute, equalizer
    }

    private struct Request {
        let dataType: UInt8
        let payload: [UInt8]
        var reply: ((UInt8, [UInt8]) -> Bool)?
        var completion: ((Bool) -> Void)?
        /// A newer request with the same key replaces this one while it waits in the queue.
        var key: String?
        var attempts = 0
        var acked = false
        var replied = false
    }

    private static let ackTimeout: Duration = .milliseconds(1200)
    private static let replyTimeout: Duration = .seconds(3)
    private static let maxAttempts = 3

    /// - Parameter capabilities: what an earlier session learned; skips most of the handshake.
    public init(transport: HeadphoneTransport, capabilities: HeadphoneCapabilities? = nil, status: HeadphoneStatus = HeadphoneStatus()) {
        self.transport = transport
        self.capabilities = capabilities
        self.status = status
        transport.delegate = self
    }

    public func start() {
        setState(.connecting)
        transport.open()
    }

    public func stop() {
        transport.close()
        close(reason: nil)
    }

    public var isBusy: Bool { inFlight != nil || !queue.isEmpty || !followUps.isEmpty }

    // MARK: Reading

    /// Re-reads parts of `status`. The completion gets false if the headphones didn't answer.
    public func load(_ scope: Scope, completion: ((Bool) -> Void)? = nil) {
        guard state == .ready, let capabilities else { completion?(false); return }
        var requests: [(table: UInt8, payload: [UInt8], reply: (UInt8, [UInt8]) -> Bool)] = []
        if scope.contains(.devices), capabilities.supportsDeviceList {
            let type = capabilities.pairingListType
            requests.append((MDRDataType.table2, MDRRequest.pairedDevices(type), Self.isReply(MDRDataType.table2, 0x37, type.rawValue)))
            if capabilities.supportsAutoSwitch {
                requests.append((MDRDataType.table2, MDRRequest.autoSwitch, Self.isReply(MDRDataType.table2, 0x37, 0x01)))
            }
        }
        if scope.contains(.noiseControl), let variant = capabilities.noiseControlVariant {
            requests.append((MDRDataType.table1, MDRRequest.noiseControl(variant), Self.isReply(MDRDataType.table1, 0x67, variant.rawValue)))
        }
        if scope.contains(.settings) {
            if let index = capabilities.sidetoneIndex {
                requests.append((MDRDataType.table1, MDRRequest.generalSetting(index), Self.isReply(MDRDataType.table1, 0xD7, index)))
            }
            if capabilities.supportsSpeakToChat {
                requests.append((MDRDataType.table1, MDRRequest.speakToChat, Self.isReply(MDRDataType.table1, 0xF7, 0x0C)))
                requests.append((MDRDataType.table1, MDRRequest.speakToChatDetail, Self.isReply(MDRDataType.table1, 0xFB, 0x0C)))
            }
            if capabilities.supportsMicMute {
                requests.append((MDRDataType.table2, MDRRequest.micMute, Self.isReply(MDRDataType.table2, 0xF7, 0x0B)))
            }
        }
        // Last, so that if these headphones turn out not to answer, nothing else waits behind it.
        // Whether the equalizer is available is asked under the type the headphones advertise; they ignore the
        // question otherwise. It's a nicety, so a model that doesn't answer it doesn't fail the whole read.
        var optional: Set<[UInt8]> = []
        if scope.contains(.equalizer), let equalizer = capabilities.equalizer {
            requests.append((MDRDataType.table1, MDRRequest.equalizer, Self.isEqualizerReply(0x57)))
            let availability = MDRRequest.equalizerAvailability(equalizer.variant)
            requests.append((MDRDataType.table1, availability, Self.isEqualizerReply(0x53)))
            optional.insert(availability)
        }
        guard !requests.isEmpty else { completion?(true); return }
        var allAnswered = true
        for (position, request) in requests.enumerated() {
            let isLast = position == requests.count - 1
            send(request.table, request.payload, reply: request.reply, key: "get \(request.table) \(request.payload)") { ok in
                allAnswered = allAnswered && (ok || optional.contains(request.payload))
                if isLast { completion?(allAnswered) }
            }
        }
    }

    // MARK: Devices

    /// Makes a connected device the audio source. The completion gets nil on success, else a user-facing reason.
    public func switchPlayback(to target: PairedDevice, completion: ((String?) -> Void)? = nil) {
        var code: UInt8?
        send(MDRDataType.table2, MDRRequest.switchSource(to: target.addressBytes), reply: { type, payload in
            // The headphones answer with a result notification rather than a reply.
            guard type == MDRDataType.table2, payload.count >= 3, payload[0] == 0x3D, payload[1] == 0x01 else { return false }
            code = payload[2]
            return true
        }) { [weak self] _ in
            guard let self else { return }
            switch code {
            case 0x00?:
                completion?(nil)
                // The list can lag the notification, so confirm a moment later.
                self.followUp(after: .milliseconds(1500)) { $0.load(.devices) { _ in } }
            case let failure?:
                completion?(SourceSwitchResult(rawValue: failure)?.message ?? "Switching failed (code \(failure))")
            case nil:
                // Not every firmware sends the notification; see what the list says.
                self.load(.devices) { [weak self] _ in
                    let switched = self?.status.device(matching: target.address)?.isPlaying == true
                    completion?(switched ? nil : "The headphones didn't switch to \(target.name)")
                }
            }
        }
    }

    public func connect(_ target: PairedDevice, completion: ((String?) -> Void)? = nil) {
        setConnected(true, target, completion: completion)
    }

    public func disconnect(_ target: PairedDevice, completion: ((String?) -> Void)? = nil) {
        setConnected(false, target, completion: completion)
    }

    private func setConnected(_ connected: Bool, _ target: PairedDevice, completion: ((String?) -> Void)?) {
        guard let type = capabilities?.pairingListType else { completion?("Not connected"); return }
        send(MDRDataType.table2, MDRRequest.connectivity(connected ? .connect : .disconnect, type, address: target.addressBytes))
        // Connecting takes the headphones a few seconds; watch the list until it shows.
        watchDevice(target, tries: connected ? 6 : 4, until: { $0?.isConnected == connected }) { reached in
            completion?(reached ? nil : "Couldn't \(connected ? "connect" : "disconnect") \(target.name)")
        }
    }

    private func watchDevice(_ target: PairedDevice, tries: Int, until reached: @escaping (PairedDevice?) -> Bool,
                             completion: @escaping (Bool) -> Void) {
        followUp(after: .milliseconds(1200), onCancel: { completion(false) }) { session in
            session.load(.devices) { [weak session] _ in
                guard let session else { return }
                if reached(session.status.device(matching: target.address)) {
                    completion(true)
                } else if tries > 1 {
                    session.watchDevice(target, tries: tries - 1, until: reached, completion: completion)
                } else {
                    completion(false)
                }
            }
        }
    }

    // MARK: Settings

    public func setAutoSwitch(_ enabled: Bool) {
        guard capabilities?.supportsAutoSwitch == true else { return }
        write(.autoSwitch, MDRDataType.table2, MDRRequest.setAutoSwitch(enabled),
              readBack: MDRRequest.autoSwitch, reply: Self.isReply(MDRDataType.table2, 0x37, 0x01))
    }

    /// - Parameter adjusting: true while a slider is being dragged; send once more with false when it's released.
    public func setNoiseControl(_ value: NoiseControl, adjusting: Bool = false) {
        guard capabilities?.noiseControlVariant == value.variant else { return }
        write(.noiseControl, MDRDataType.table1, MDRRequest.setNoiseControl(value, adjusting: adjusting),
              readBack: adjusting ? nil : MDRRequest.noiseControl(value.variant),
              reply: Self.isReply(MDRDataType.table1, 0x67, value.variant.rawValue))
    }

    public func setSidetone(_ on: Bool) {
        guard let index = capabilities?.sidetoneIndex else { return }
        write(.sidetone, MDRDataType.table1, MDRRequest.setGeneralSetting(index, on: on),
              readBack: MDRRequest.generalSetting(index), reply: Self.isReply(MDRDataType.table1, 0xD7, index))
    }

    public func setSpeakToChat(_ on: Bool) {
        guard capabilities?.supportsSpeakToChat == true else { return }
        write(.speakToChat, MDRDataType.table1, MDRRequest.setSpeakToChat(on),
              readBack: MDRRequest.speakToChat, reply: Self.isReply(MDRDataType.table1, 0xF7, 0x0C))
    }

    public func setSpeakToChatDetail(_ detail: SpeakToChatDetail) {
        guard capabilities?.supportsSpeakToChat == true else { return }
        write(.speakToChatDetail, MDRDataType.table1, MDRRequest.setSpeakToChatDetail(detail),
              readBack: MDRRequest.speakToChatDetail, reply: Self.isReply(MDRDataType.table1, 0xFB, 0x0C))
    }

    public func setMicMute(_ settings: MicMuteSettings) {
        guard capabilities?.supportsMicMute == true else { return }
        write(.micMute, MDRDataType.table2, MDRRequest.setMicMute(settings),
              readBack: MDRRequest.micMute, reply: Self.isReply(MDRDataType.table2, 0xF7, 0x0B))
    }

    /// Selects an equalizer preset. The read-back brings that preset's bands.
    public func selectEqualizerPreset(_ id: UInt8) {
        guard capabilities?.equalizer != nil else { return }
        write(.equalizer, MDRDataType.table1, MDRRequest.selectEqualizerPreset(id),
              readBack: MDRRequest.equalizer, reply: Self.isEqualizerReply(0x57))
    }

    /// Sets the bands of a custom preset.
    /// - Parameter adjusting: true while a slider is being dragged; send once more with false when it's released.
    public func setEqualizer(_ value: Equalizer, adjusting: Bool = false) {
        guard capabilities?.equalizer?.isCustomizable == true, !value.steps.isEmpty else { return }
        write(.equalizer, MDRDataType.table1, MDRRequest.setEqualizer(value),
              readBack: adjusting ? nil : MDRRequest.equalizer, reply: Self.isEqualizerReply(0x57))
    }

    /// Sends a setting, then reads it back to confirm. Repeated writes of one setting collapse to the newest.
    private func write(_ setting: Setting, _ table: UInt8, _ payload: [UInt8], readBack: [UInt8]?,
                       reply: @escaping (UInt8, [UInt8]) -> Bool) {
        // A write that replaces a queued one inherits its completion, so the count still balances.
        writing[setting, default: 0] += 1
        send(table, payload, key: "set \(setting)") { [weak self] _ in
            self?.writing[setting, default: 1] -= 1
        }
        if let readBack {
            send(table, readBack, reply: reply, key: "get \(table) \(readBack)")
        }
    }

    private func isWriting(_ setting: Setting) -> Bool { writing[setting, default: 0] > 0 }

    /// Sends a raw request and hands back the reply: the next packet on the same table whose command byte is the
    /// request's plus one and whose second byte (the inquired type) matches. For protocol exploration.
    public func query(table: UInt8, _ payload: [UInt8], completion: @escaping ([UInt8]?) -> Void) {
        var answer: [UInt8]?
        send(table, payload, reply: { type, reply in
            guard type == table, reply.count >= 2, let command = payload.first, reply[0] == command &+ 1,
                  payload.count < 2 || reply[1] == payload[1] else { return false }
            answer = reply
            return true
        }) { _ in completion(answer) }
    }

    // MARK: Handshake

    public func transportDidOpen(_ transport: HeadphoneTransport) {
        log?("channel open")
        // Protocol info must be the first thing sent on every connection.
        send(MDRDataType.table1, MDRRequest.protocolInfo, reply: { type, payload in
            type == MDRDataType.table1 && payload.first == 0x01
        }) { [weak self] ok in
            guard let self else { return }
            guard ok else { return self.fail("The headphones didn't answer") }
            if let info = self.protocolInfo, !info.hasTable2 {
                return self.fail("These headphones don't support multipoint control")
            }
            if let known = self.capabilities {
                // Capabilities remembered from before the app knew about the equalizer: ask about that once.
                guard known.equalizerProbed != true, known.equalizerVariant != nil else { return self.setState(.ready) }
                self.discovered = known
                return self.describeEqualizer()
            }
            self.send(MDRDataType.table1, MDRRequest.supportFunctions, reply: { type, payload in
                type == MDRDataType.table1 && payload.first == 0x07
            })
            self.send(MDRDataType.table2, MDRRequest.supportFunctions, reply: { type, payload in
                type == MDRDataType.table2 && payload.first == 0x07
            }) { [weak self] _ in self?.describeGeneralSettings() }
        }
    }

    /// The general settings name themselves ("SIDETONE_SETTING"); ask each one what it is.
    private func describeGeneralSettings() {
        let indexes = T1Function.generalSettings.filter(discovered.supportedT1.contains)
        guard !indexes.isEmpty else { return describeEqualizer() }
        for index in indexes {
            send(MDRDataType.table1, MDRRequest.generalSettingInfo(index),
                 reply: Self.isReply(MDRDataType.table1, 0xD1, index)) { [weak self] _ in
                if index == indexes.last { self?.describeEqualizer() }
            }
        }
    }

    /// The equalizer's presets and bands differ by model, so the headphones are asked for them.
    private func describeEqualizer() {
        guard let variant = discovered.equalizerVariant else {
            discovered.equalizerProbed = true
            return finishHandshake()
        }
        send(MDRDataType.table1, MDRRequest.equalizerInfo(variant), reply: Self.isEqualizerReply(0x51)) { [weak self] _ in
            self?.discovered.equalizerProbed = true
            self?.finishHandshake()
        }
    }

    private func finishHandshake() {
        guard case .connecting = state else { return }
        capabilities = discovered
        setState(.ready)
    }

    private static func isReply(_ table: UInt8, _ command: UInt8, _ inquiredType: UInt8) -> (UInt8, [UInt8]) -> Bool {
        { dataType, payload in
            dataType == table && payload.count >= 2 && payload[0] == command && payload[1] == inquiredType
        }
    }

    /// A reply about the equalizer. The headphones may answer under any of the preset-equalizer types.
    private static func isEqualizerReply(_ command: UInt8) -> (UInt8, [UInt8]) -> Bool {
        { dataType, payload in
            dataType == MDRDataType.table1 && payload.count >= 2 && payload[0] == command && [0x00, 0x02, 0x04].contains(payload[1])
        }
    }

    /// Runs `work` after a delay, keeping the session busy (and so open) until then. If the session closes first,
    /// `onCancel` runs instead, so callers waiting on the outcome always hear back.
    private func followUp(after delay: Duration, onCancel: (() -> Void)? = nil, _ work: @escaping (HeadphoneSession) -> Void) {
        let id = UUID()
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.followUps[id] = nil
            work(self)
            self.noteIfIdle()
        }
        followUps[id] = (task, onCancel)
    }

    // MARK: Transport

    private func send(_ dataType: UInt8, _ payload: [UInt8], reply: ((UInt8, [UInt8]) -> Bool)? = nil,
                      key: String? = nil, completion: ((Bool) -> Void)? = nil) {
        if case .closed = state { completion?(false); return }
        var request = Request(dataType: dataType, payload: payload, reply: reply, completion: completion, key: key)
        if let key, let index = queue.firstIndex(where: { $0.key == key }) {
            // Keep the older request's completion alive so nobody waits forever.
            let replaced = queue.remove(at: index)
            if let earlier = replaced.completion {
                request.completion = { ok in earlier(ok); completion?(ok) }
            }
        }
        queue.append(request)
        pump()
    }

    private func pump() {
        guard inFlight == nil, !queue.isEmpty else { return }
        transmit(queue.removeFirst())
    }

    private func transmit(_ request: Request) {
        var request = request
        request.attempts += 1
        inFlight = request
        let packet = MDRPacket(dataType: request.dataType, sequence: sequence, payload: request.payload)
        log?(">> \(hex(packet))")
        transport.write(MDRCodec.encode(packet))
        armTimeout(Self.ackTimeout)
    }

    private func armTimeout(_ duration: Duration) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.timedOut()
        }
    }

    private func timedOut() {
        guard let request = inFlight else { return }
        if !request.acked {
            if request.attempts < Self.maxAttempts {
                log?("ACK timeout, retrying")
                transmit(request) // same sequence number, as the protocol expects
            } else {
                fail("The headphones stopped responding")
            }
        } else {
            log?("reply timeout")
            finishInFlight(ok: false)
        }
    }

    private func finishInFlight(ok: Bool) {
        timeout?.cancel()
        let completion = inFlight?.completion
        inFlight = nil
        completion?(ok)
        pump()
        noteIfIdle()
    }

    private func noteIfIdle() {
        if state == .ready, !isBusy { onIdle?() }
    }

    public func transport(_ transport: HeadphoneTransport, didReceive bytes: [UInt8]) {
        for packet in decoder.feed(bytes) {
            handle(packet)
        }
    }

    private func handle(_ packet: MDRPacket) {
        log?("<< \(hex(packet))")
        switch packet.dataType {
        case MDRDataType.ack:
            guard var request = inFlight, packet.sequence == Self.other(sequence) else { return }
            sequence = packet.sequence
            request.acked = true
            inFlight = request
            if request.reply == nil || request.replied {
                finishInFlight(ok: true)
            } else {
                armTimeout(Self.replyTimeout)
            }

        case MDRDataType.table1, MDRDataType.table2:
            transport.write(MDRCodec.encode(MDRPacket(dataType: MDRDataType.ack, sequence: Self.other(packet.sequence))))
            if packet.dataType == MDRDataType.table1 {
                if let info = MDRParser.protocolInfo(packet.payload) {
                    protocolInfo = info
                } else if let message = MDRParser.parseT1(packet.payload) {
                    apply(message)
                }
            } else if let message = MDRParser.parseT2(packet.payload) {
                apply(message)
            }
            if var request = inFlight, let matches = request.reply, matches(packet.dataType, packet.payload) {
                request.replied = true
                inFlight = request
                if request.acked { finishInFlight(ok: true) }
            }

        default:
            break
        }
    }

    private func apply(_ message: T1Message) {
        switch message {
        case let .supportFunctions(functions):
            discovered.supportedT1 = functions
        case let .generalSettingInfo(info):
            discovered.generalSettings.removeAll { $0.index == info.index }
            discovered.generalSettings.append(info)
        case let .generalSetting(index, on):
            if index == (capabilities ?? discovered).sidetoneIndex, !isWriting(.sidetone) { status.sidetone = on }
        case let .speakToChat(enabled):
            if !isWriting(.speakToChat) { status.speakToChat = enabled }
        case let .speakToChatDetail(detail):
            if !isWriting(.speakToChatDetail) { status.speakToChatDetail = detail }
        case let .noiseControl(value, _):
            if !isWriting(.noiseControl) { status.noiseControl = value }
        case let .equalizerInfo(info):
            discovered.equalizer = info
        case let .equalizer(value):
            guard !isWriting(.equalizer) else { break }
            // A notification that only names the new preset keeps the bands until they're read.
            status.equalizer = value.steps.isEmpty ? Equalizer(presetID: value.presetID, steps: status.equalizer?.steps ?? []) : value
        case let .equalizerAvailable(available):
            status.equalizerAvailable = available
        case .other:
            break
        }
    }

    private func apply(_ message: T2Message) {
        switch message {
        case let .supportFunctions(functions):
            discovered.supportedT2 = functions
        case let .pairedDevices(list, _):
            status.devices = list
        case let .autoSwitch(enabled):
            if !isWriting(.autoSwitch) { status.autoSwitch = enabled }
        case let .micMute(settings):
            if !isWriting(.micMute) { status.micMute = settings }
        case let .sourceSwitchResult(code, address):
            guard code == SourceSwitchResult.success.rawValue else { return }
            let target = normalizeAddress(address)
            var devices = status.devices
            for index in devices.indices {
                devices[index].isPlaying = devices[index].isConnected && devices[index].normalizedAddress == target
            }
            status.devices = devices
        case let .connectivityResult(action, result, address):
            // Low nibble: 0 success, 1 error, 2 in progress, 3 busy. Success and failure show up in the device list,
            // which is being watched; "busy" is worth saying out loud.
            guard result & 0x0F == 0x03 else { return }
            let name = status.device(matching: address)?.name ?? address
            let verb = action == ConnectivityAction.connect.rawValue ? "connect" : "disconnect"
            onNotice?("The headphones are busy and couldn't \(verb) \(name)")
        case .other:
            break
        }
    }

    // MARK: Lifecycle

    public func transport(_ transport: HeadphoneTransport, didCloseWithError error: String?) {
        close(reason: error)
    }

    private func fail(_ reason: String) {
        transport.close()
        close(reason: reason)
    }

    private func close(reason: String?) {
        if case .closed = state { return }
        timeout?.cancel()
        let cancelled = followUps.values
        followUps.removeAll()
        cancelled.forEach { $0.task.cancel() }
        let pending = (inFlight.map { [$0] } ?? []) + queue
        inFlight = nil
        queue.removeAll()
        setState(.closed(reason))
        pending.forEach { $0.completion?(false) }
        cancelled.forEach { $0.onCancel?() }
    }

    private func setState(_ newState: State) {
        state = newState
        onChange?()
    }

    private static func other(_ sequence: UInt8) -> UInt8 { sequence == 0 ? 1 : 0 }

    private func hex(_ packet: MDRPacket) -> String {
        let payload = packet.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        return String(format: "type=%02X seq=%d ", packet.dataType, packet.sequence) + payload
    }
}
