// swift-tools-version:5.9
import PackageDescription

let infoPlist = Context.packageDirectory + "/Resources/Info.plist"

let package = Package(
    name: "Multipoint",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        // What the iOS app (iOS/Multipoint.xcodeproj) builds on.
        .library(name: "HeadphoneKit", targets: ["HeadphoneKit", "MDRKit"]),
    ],
    targets: [
        // Pure-Swift subset of Sony's MDR v2 protocol: framing + messages. No Bluetooth, fully testable.
        .target(name: "MDRKit"),
        // The protocol session and the connect-on-demand controller, over any byte transport. Shared by macOS and iOS.
        .target(name: "HeadphoneKit", dependencies: ["MDRKit"]),
        .executableTarget(
            name: "Multipoint",
            dependencies: ["MDRKit", "HeadphoneKit"],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreAudio"),
                // Embed Info.plist so the bare binary (CLI mode) also carries the Bluetooth usage description.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        ),
        .testTarget(name: "MDRKitTests", dependencies: ["MDRKit"]),
        .testTarget(name: "HeadphoneKitTests", dependencies: ["HeadphoneKit"]),
        .testTarget(name: "MultipointTests", dependencies: ["Multipoint"]),
    ]
)
