/// A byte pipe to the headphones' control service: RFCOMM on the Mac, an accessory session or GATT on iOS.
@MainActor
public protocol HeadphoneTransport: AnyObject {
    var delegate: HeadphoneTransportDelegate? { get set }
    func open()
    /// Closes the pipe without notifying the delegate.
    func close()
    func write(_ bytes: [UInt8])
}

@MainActor
public protocol HeadphoneTransportDelegate: AnyObject {
    func transportDidOpen(_ transport: HeadphoneTransport)
    func transport(_ transport: HeadphoneTransport, didReceive bytes: [UInt8])
    /// The pipe failed to open or went away. `error` is user-facing.
    func transport(_ transport: HeadphoneTransport, didCloseWithError error: String?)
}
