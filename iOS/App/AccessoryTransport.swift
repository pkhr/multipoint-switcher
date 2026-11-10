import ExternalAccessory
import Foundation
import HeadphoneKit

/// The headphones' control channel on iOS: an accessory session carrying the same byte stream the Mac gets over
/// RFCOMM. Sony's headphones are "Made for iPhone" accessories and offer it under the protocol name below.
///
/// iOS gives the session to one app at a time, so Sound Connect can't use it while this is open. That's the reason
/// for opening it only for as long as a command takes.
@MainActor
final class AccessoryTransport: NSObject, HeadphoneTransport, StreamDelegate {
    /// Sony's MDR protocol, version 2 (WH-1000XM5 and later). Must also be listed in Info.plist.
    static let protocolName = "jp.co.sony.songpal.mdr.link2"

    /// The connected headphones, if they're offering the control protocol right now.
    static var connectedHeadphones: EAAccessory? {
        EAAccessoryManager.shared().connectedAccessories.first { $0.protocolStrings.contains(protocolName) }
    }

    weak var delegate: HeadphoneTransportDelegate?

    private let accessory: EAAccessory
    private var session: EASession?
    private var pending: [UInt8] = []
    private var inputOpen = false
    private var outputOpen = false
    private var announced = false
    private var openTimeout: Task<Void, Never>?

    init(accessory: EAAccessory) {
        self.accessory = accessory
    }

    func open() {
        guard accessory.isConnected, let session = EASession(accessory: accessory, forProtocol: Self.protocolName),
              let input = session.inputStream, let output = session.outputStream else {
            // Report after returning, like a real connection attempt would.
            Task { [weak self] in
                guard let self else { return }
                self.delegate?.transport(self, didCloseWithError: "Couldn't reach the headphones. If Sound Connect is open, close it and try again.")
            }
            return
        }
        self.session = session
        for stream in [input, output] as [Stream] {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .common)
            stream.open()
        }
        openTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, !self.announced else { return }
            self.fail("The headphones didn't open the control channel")
        }
    }

    func close() {
        openTimeout?.cancel()
        guard let session else { return }
        self.session = nil
        for stream in [session.inputStream, session.outputStream].compactMap({ $0 as Stream? }) {
            stream.delegate = nil
            stream.close()
            stream.remove(from: .main, forMode: .common)
        }
        pending.removeAll()
        inputOpen = false
        outputOpen = false
    }

    func write(_ bytes: [UInt8]) {
        pending += bytes
        flush()
    }

    private func flush() {
        guard let output = session?.outputStream, outputOpen else { return }
        while !pending.isEmpty, output.hasSpaceAvailable {
            let written = pending.withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: min($0.count, 2048)) }
            guard written > 0 else {
                if written < 0 { fail("Couldn't send to the headphones") }
                return
            }
            pending.removeFirst(written)
        }
    }

    private func fail(_ message: String?) {
        close()
        delegate?.transport(self, didCloseWithError: message)
    }

    // Streams scheduled on the main run loop call back on the main thread.
    nonisolated func stream(_ stream: Stream, handle event: Stream.Event) {
        MainActor.assumeIsolated { handle(event, from: stream) }
    }

    private func handle(_ event: Stream.Event, from stream: Stream) {
        guard let session, stream === session.inputStream || stream === session.outputStream else { return }
        switch event {
        case .openCompleted:
            if stream === session.inputStream { inputOpen = true } else { outputOpen = true }
            if inputOpen, outputOpen, !announced {
                announced = true
                openTimeout?.cancel()
                delegate?.transportDidOpen(self)
                flush()
            }
        case .hasBytesAvailable:
            guard let input = session.inputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                delegate?.transport(self, didReceive: Array(buffer[..<count]))
            }
        case .hasSpaceAvailable:
            flush()
        case .errorOccurred:
            fail("The connection to the headphones failed")
        case .endEncountered:
            fail("The headphones closed the control channel")
        default:
            break
        }
    }
}
