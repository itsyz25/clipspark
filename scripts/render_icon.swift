// Renders brand/appicon-ios.svg → the 1024px iOS app icon PNG.
// Uses AppKit's native SVG support — no external dependencies.
import AppKit

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svgURL = repo.appendingPathComponent("brand/appicon-ios.svg")
let outURL = repo.appendingPathComponent("ClipSpark/Assets.xcassets/AppIcon.appiconset/icon1024.png")

guard let image = NSImage(contentsOf: svgURL) else {
    fatalError("Could not load SVG at \(svgURL.path)")
}

let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("bitmap rep failed") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG encode failed")
}
try! FileManager.default.createDirectory(
    at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true
)
try! png.write(to: outURL)
print("Rendered icon1024.png (\(png.count) bytes)")
