// Turns a product photo into the app's hero image: lifts the headphones off whatever is behind them (and away from
// any captions around them), makes the picture black and white, trims it, and writes a PNG with transparency. The
// app then shows it over its own dark backdrop.
//
//     swift iOS/Tools/CutOutPhoto.swift photo.png iOS/App/Assets.xcassets/Headphones.imageset/Headphones.png
import AppKit
import CoreImage
import Vision

let arguments = CommandLine.arguments
guard arguments.count >= 3, let source = NSImage(contentsOfFile: arguments[1]),
      let photo = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: CutOutPhoto.swift <photo> <output.png>")
    exit(1)
}

// Vision separates the picture into foreground objects. Captions and badges come out as their own small objects,
// so keep the biggest one and anything nearly as big (a second earcup, say, if it was split off).
let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: photo)
try handler.perform([request])
guard let observation = request.results?.first else {
    print("Couldn't find anything in the foreground of this picture.")
    exit(1)
}
let labels = observation.instanceMask
CVPixelBufferLockBaseAddress(labels, .readOnly)
var areas: [UInt8: Int] = [:]
let labelBytes = CVPixelBufferGetBaseAddress(labels)!.assumingMemoryBound(to: UInt8.self)
for y in 0..<CVPixelBufferGetHeight(labels) {
    for x in 0..<CVPixelBufferGetWidth(labels) {
        let label = labelBytes[y * CVPixelBufferGetBytesPerRow(labels) + x]
        if label != 0 { areas[label, default: 0] += 1 }
    }
}
CVPixelBufferUnlockBaseAddress(labels, .readOnly)
let largest = areas.values.max() ?? 0
let kept = IndexSet(areas.filter { $0.value * 4 >= largest }.keys.map(Int.init))
print("foreground objects: \(areas.count), kept: \(kept.count)")

let mask = try observation.generateScaledMaskForImage(forInstances: kept, from: handler)

// Where the kept object is, for trimming.
CVPixelBufferLockBaseAddress(mask, .readOnly)
let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
let rowBytes = CVPixelBufferGetBytesPerRow(mask)
let maskBase = CVPixelBufferGetBaseAddress(mask)!
var minX = width, maxX = 0, minY = height, maxY = 0
for y in 0..<height {
    let row = maskBase.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
    for x in 0..<width where row[x] > 0.2 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
CVPixelBufferUnlockBaseAddress(mask, .readOnly)
guard maxX > minX, maxY > minY else {
    print("The foreground mask came out empty.")
    exit(1)
}

// Pull the mask in by a couple of pixels so no rim of the old backdrop comes along, then cut, and drop the colour.
let extent = CGRect(x: 0, y: 0, width: photo.width, height: photo.height)
let softMask = CIImage(cvPixelBuffer: mask)
    .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 2.0])
    .applyingGaussianBlur(sigma: 0.8)
    .cropped(to: extent)
// Black headphones on a dark backdrop need their midtones lifted a little to keep their shape; blacks stay black.
var image = CIImage(cgImage: photo)
    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
    .applyingFilter("CIToneCurve", parameters: [
        "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.12, y: 0.17), "inputPoint2": CIVector(x: 0.3, y: 0.42),
        "inputPoint3": CIVector(x: 0.6, y: 0.74), "inputPoint4": CIVector(x: 1, y: 1),
    ])
    .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: softMask])

// Core Image counts rows from the bottom; the mask rows above were counted from the top.
let pad = CGFloat(max(maxX - minX, maxY - minY)) * 0.04
let box = CGRect(x: CGFloat(minX), y: CGFloat(height - 1 - maxY), width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    .insetBy(dx: -pad, dy: -pad).intersection(extent)
image = image.cropped(to: box).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
let scale = min(1, 1400 / max(box.width, box.height))
if scale < 1 {
    image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
}

let context = CIContext()
let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
try NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
print("wrote \(arguments[2]) \(result.width)×\(result.height)")
