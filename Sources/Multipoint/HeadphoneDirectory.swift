import Foundation
import IOBluetooth
import MDRKit

/// Finds paired Sony headphones that speak MDR v2, and knows a little about the Mac's own Bluetooth identity.
@MainActor
enum HeadphoneDirectory {
    private static let sonyVendorID = 0x054C
    private static let audioMajorClass: BluetoothDeviceClassMajor = 0x04

    static func candidates() -> [IOBluetoothDevice] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.filter(isSonyHeadphones)
    }

    /// The device to use: the remembered one, else a connected candidate, else any candidate.
    static func preferred(rememberedAddress: String?) -> IOBluetoothDevice? {
        let all = candidates()
        if let rememberedAddress, let match = all.first(where: { $0.normalizedAddress == rememberedAddress }) {
            return match
        }
        return all.first { $0.isConnected() } ?? all.first
    }

    static func find(_ query: String) -> IOBluetoothDevice? {
        let all = candidates()
        let normalized = normalizeAddress(query)
        return all.first { $0.normalizedAddress == normalized && !normalized.isEmpty }
            ?? all.first { ($0.name ?? "").localizedCaseInsensitiveContains(query) }
    }

    static var hostAddress: String? {
        IOBluetoothHostController.default()?.addressAsString().map(normalizeAddress)
    }

    private static func isSonyHeadphones(_ device: IOBluetoothDevice) -> Bool {
        if device.getServiceRecord(for: BluetoothLink.mdrServiceV2) != nil { return true }
        // SDP cache may lack the Sony service; fall back to the PnP record's vendor ID.
        return device.deviceClassMajor == audioMajorClass && vendorID(of: device) == sonyVendorID
    }

    private static func vendorID(of device: IOBluetoothDevice) -> Int? {
        guard let pnp = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1200)),
              let element = pnp.getAttributeDataElement(0x0201) else { return nil }
        return element.getNumberValue()?.intValue
    }
}

extension IOBluetoothDevice {
    /// The address as hex digits only, or "" for devices that don't report one. Bluetooth LE devices often don't,
    /// and `addressString` is then nil even though it's declared as always present.
    var normalizedAddress: String {
        (addressString as String?).map(normalizeAddress) ?? ""
    }
}

/// Runs `work` on the main actor: right away when already on the main thread, otherwise shortly after.
///
/// IOBluetooth is documented to call back on the main thread, but on recent macOS some of its notifications arrive
/// on its own queue instead, so nothing that it calls may assume which thread it's on.
func onMainActor(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(work)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}
