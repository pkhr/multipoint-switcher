// Makes both apps' icons from the hero photo: the headphones, close up, on the app's dark grey to black backdrop.
//
//     swift iOS/Tools/MakeIcons.swift        (run from the repository root)
//
// Writes iOS/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png and Resources/AppIcon.icns.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let photo = NSImage(contentsOf: root.appendingPathComponent("iOS/App/Assets.xcassets/Headphones.imageset/Headphones.png"))!

func bitmap(_ size: Int, opaque: Bool, _ draw: (CGContext) -> Void) -> CGImage {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    draw(context)
    NSGraphicsContext.current = nil
    return context.makeImage()!
}

func write(_ image: CGImage, _ url: URL) {
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

/// The artwork, edge to edge. iOS rounds the corners itself.
let artwork = bitmap(1024, opaque: true) { context in
    let backdrop = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0.25, alpha: 1), CGColor(gray: 0.06, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray,
                              locations: [0, 0.62, 1])!
    context.drawLinearGradient(backdrop, start: CGPoint(x: 0, y: 1024), end: .zero, options: [])
    let glow = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0.06), CGColor(gray: 1, alpha: 0)] as CFArray,
                          locations: [0, 0.55, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 544), startRadius: 0, endCenter: CGPoint(x: 512, y: 544), endRadius: 520, options: [])
    // Close enough that the near earcup fills the frame and the band runs off the top.
    let pixels = photo.representations[0]
    let height: CGFloat = 800 * 1.42, width = height * CGFloat(pixels.pixelsWide) / CGFloat(pixels.pixelsHigh)
    photo.draw(in: NSRect(x: 512 - width / 2 - 70, y: 512 - height / 2 + 120, width: width, height: height))
}
write(artwork, root.appendingPathComponent("iOS/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))

/// The Mac's version sits inside the standard rounded square, with room around it and a soft shadow.
let mac = bitmap(1024, opaque: false) { context in
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: CGColor(gray: 0, alpha: 0.45))
    context.addPath(shape)
    context.setFillColor(gray: 0, alpha: 1)
    context.fillPath()
    context.restoreGState()
    context.addPath(shape)
    context.clip()
    context.draw(artwork, in: plate)
}
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Multipoint-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let size = points * scale
    let scaled = bitmap(size, opaque: false) { context in
        context.interpolationQuality = .high
        context.draw(mac, in: CGRect(x: 0, y: 0, width: size, height: size))
    }
    write(scaled, iconset.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("wrote the iOS icon and Resources/AppIcon.icns")
