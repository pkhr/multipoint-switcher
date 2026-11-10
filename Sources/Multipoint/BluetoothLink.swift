import Foundation
import HeadphoneKit
import IOBluetooth

/// An RFCOMM channel to the headphones' Sony control service. IOBluetooth delivers every callback on the main run loop.
@MainActor
final class BluetoothLink: NSObject, HeadphoneTransport, IOBluetoothRFCOMMChannelDelegate {
    /// SDP service UUID of MDR protocol v2 (WH-1000XM5 and later, incl. 1000X The ColleXion).
    static let mdrServiceV2: IOBluetoothSDPUUID = {
        let bytes: [UInt8] = [0x95, 0x6C, 0x7B, 0x26, 0xD4, 0x9A, 0x4B, 0xA8,
                              0xB0, 0x3F, 0xB1, 0x7D, 0x39, 0x3C, 0xB6, 0xE2]
        return IOBluetoothSDPUUID(bytes: bytes, length: 16)
    }()

    let device: IOBluetoothDevice
    weak var delegate: HeadphoneTransportDelegate?

    private var channel: IOBluetoothRFCOMMChannel?
    private var isOpen = false
    private var didQuerySDP = false
    private var openAttempts = 0
    private var openTimeout: Task<Void, Never>?
    /// IOBluetooth silently drops RFCOMM opens issued before its internal CoreBluetooth session reports
    /// "powered on" ("API MISUSE: … can only accept this command while in the powered on state"), which
    /// happens asynchronously shortly after a process first touches Bluetooth.
    private static var stackWarmedUp = false
    private var pendingWrites: [[UInt8]] = []
    private var writeBuffer: UnsafeMutableRawPointer?

    init(device: IOBluetoothDevice) {
        self.device = device
    }

    /// Starts IOBluetooth's session ahead of time, so the first connection doesn't have to wait for it.
    static func warmUp() {
        guard warmUpTask == nil else { return }
        _ = IOBluetoothHostController.default()?.powerState
        warmUpTask = Task {
            try? await Task.sleep(for: .seconds(1))
            stackWarmedUp = true
        }
    }

    private static var warmUpTask: Task<Void, Never>?

    func open() {
        openAttempts = 0
        guard Self.stackWarmedUp else {
            Self.warmUp()
            Task { [weak self] in
                await Self.warmUpTask?.value
                self?.openChannel()
            }
            return
        }
        openChannel()
    }

    private func openChannel() {
        guard let record = device.getServiceRecord(for: Self.mdrServiceV2) else {
            // Cached SDP records can be stale; ask the headphones once before giving up.
            if !didQuerySDP {
                didQuerySDP = true
                if device.performSDPQuery(self, uuids: [Self.mdrServiceV2]) == kIOReturnSuccess { return }
            }
            fail("These headphones don't expose Sony's v2 control service")
            return
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            fail("Couldn't find the control channel in the headphones' service record")
            return
        }
        var newChannel: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&newChannel, withChannelID: channelID, delegate: self)
        guard result == kIOReturnSuccess else {
            fail(String(format: "Couldn't open the control channel (IOReturn 0x%08x)", result))
            return
        }
        channel = newChannel
        openAttempts += 1
        // An open that IOBluetooth dropped never calls back, so retry rather than wait forever.
        openTimeout?.cancel()
        openTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, !self.isOpen else { return }
            if self.openAttempts < 3 {
                if let channel = self.channel {
                    _ = channel.setDelegate(nil)
                    _ = channel.close()
                }
                self.channel = nil
                self.openChannel()
            } else {
                self.fail("The headphones didn't open the control channel. Another app may be using it.")
            }
        }
    }

    /// Closes the channel without notifying the delegate.
    func close() {
        if let channel {
            _ = channel.setDelegate(nil)
            _ = channel.close()
        }
        teardown()
    }

    func write(_ bytes: [UInt8]) {
        pendingWrites.append(bytes)
        flush()
    }

    private func flush() {
        guard isOpen, writeBuffer == nil, let channel, !pendingWrites.isEmpty else { return }
        let mtu = max(Int(channel.getMTU()), 32)
        var chunk = pendingWrites[0]
        if chunk.count > mtu {
            pendingWrites[0] = Array(chunk[mtu...])
            chunk = Array(chunk[..<mtu])
        } else {
            pendingWrites.removeFirst()
        }
        // writeAsync keeps reading from the buffer until rfcommChannelWriteComplete fires.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk.count, alignment: 1)
        chunk.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: chunk.count) }
        writeBuffer = buffer
        let result = channel.writeAsync(buffer, length: UInt16(chunk.count), refcon: nil)
        if result != kIOReturnSuccess {
            fail(String(format: "Bluetooth write failed (IOReturn 0x%08x)", result))
        }
    }

    private func teardown() {
        openTimeout?.cancel()
        openTimeout = nil
        channel = nil
        isOpen = false
        pendingWrites.removeAll()
        writeBuffer?.deallocate()
        writeBuffer = nil
    }

    private func fail(_ message: String) {
        if let channel {
            _ = channel.setDelegate(nil)
            _ = channel.close()
        }
        teardown()
        delegate?.transport(self, didCloseWithError: message)
    }

    // MARK: IOBluetooth callbacks (always delivered on the main thread)

    @objc nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        onMainActor { self.openChannel() }
    }

    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        onMainActor {
            // `channel` may still be nil if IOBluetooth calls back before openRFCOMMChannelAsync returns.
            guard self.channel == nil || rfcommChannel === self.channel else { return }
            self.channel = rfcommChannel
            guard error == kIOReturnSuccess else {
                self.fail(String(format: "The headphones refused the control channel (IOReturn 0x%08x)", error))
                return
            }
            self.isOpen = true
            self.openTimeout?.cancel()
            self.delegate?.transportDidOpen(self)
            self.flush()
        }
    }

    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        onMainActor {
            guard rfcommChannel === self.channel else { return }
            self.delegate?.transport(self, didReceive: bytes)
        }
    }

    nonisolated func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        onMainActor {
            guard rfcommChannel === self.channel else { return }
            self.writeBuffer?.deallocate()
            self.writeBuffer = nil
            if error == kIOReturnSuccess {
                self.flush()
            } else {
                self.fail(String(format: "Bluetooth write failed (IOReturn 0x%08x)", error))
            }
        }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        onMainActor {
            guard rfcommChannel === self.channel else { return }
            self.teardown()
            self.delegate?.transport(self, didCloseWithError: "The headphones closed the control channel")
        }
    }
}
