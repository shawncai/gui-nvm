import AppKit
import Foundation
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift make-icon.swift <macos-directory>\n", stderr)
    exit(1)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let source = root.appendingPathComponent("Brand/AppIcon.png")
guard let artwork = NSImage(contentsOf: source), artwork.size.width == artwork.size.height else {
    fputs("Brand/AppIcon.png must be a readable square image.\n", stderr)
    exit(1)
}
let directory = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // Only generate the platform's required resolutions. Keep the original
        // artwork and its transparent outer margin in the checked-in master.
        artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                     from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let file = "icon_\(size)x\(size)@\(scale)x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(file))
        images.append(["filename": file, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "gui-nvm", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("Contents.json"))
try Data("{\"info\":{\"author\":\"gui-nvm\",\"version\":1}}".utf8).write(to: directory.deletingLastPathComponent().appendingPathComponent("Contents.json"))
let cleanup = Process()
cleanup.executableURL = URL(fileURLWithPath: "/usr/sbin/dot_clean")
cleanup.arguments = ["./"]
cleanup.currentDirectoryURL = root.deletingLastPathComponent()
try cleanup.run()
cleanup.waitUntilExit()
guard cleanup.terminationStatus == 0 else { exit(cleanup.terminationStatus) }
