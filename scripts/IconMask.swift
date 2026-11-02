// Turns a Canva icon export into a 1024 px macOS icon master.
// Finds the rounded-square artwork inside the dark margin, then places it on the standard
// macOS grid (824 px tile, 100 px inset) with transparent rounded corners.
// Usage: swift scripts/IconMask.swift <source> <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("usage: IconMask.swift <source> <output.png>\n".utf8))
    exit(1)
}

func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// Detect the artwork bounds on a small copy: anything brighter than the near-black margin.
let probe = 512
let small = context(probe, probe)
small.draw(image, in: CGRect(x: 0, y: 0, width: probe, height: probe))
let pixels = small.data!.assumingMemoryBound(to: UInt8.self)
var minX = probe, minY = probe, maxX = 0, maxY = 0
for y in 0..<probe {
    for x in 0..<probe {
        let i = y * probe * 4 + x * 4
        if (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3 > 18 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
guard maxX > minX, maxY > minY else { fatalError("No artwork found") }

// Bitmap rows are top-down; CGImage cropping is top-left too.
let scale = Double(image.width) / Double(probe)
let side = Double(max(maxX - minX, maxY - minY) + 1) * scale
let centerX = Double(minX + maxX + 1) / 2 * scale, centerY = Double(minY + maxY + 1) / 2 * scale
let crop = CGRect(x: centerX - side / 2, y: centerY - side / 2, width: side, height: side).integral
guard let artwork = image.cropping(to: crop) else { fatalError("Crop failed") }

let canvas = context(1024, 1024)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
canvas.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
canvas.clip()
canvas.interpolationQuality = .high
canvas.draw(artwork, in: tile)

let output = URL(fileURLWithPath: args[2])
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, canvas.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Write failed") }
print("Artwork \(Int(crop.width))px at (\(Int(crop.minX)), \(Int(crop.minY))) → \(output.lastPathComponent)")
