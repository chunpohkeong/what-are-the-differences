import CoreGraphics
import Foundation
import ImageIO

public struct ImageDiff: @unchecked Sendable {
    public var width: Int
    public var height: Int
    public var differingPixels: Int
    /// Red where pixels differ, transparent elsewhere; same size as the comparison canvas.
    public var mask: CGImage?
}

public func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// Pixel compare on a canvas big enough for both images, aligned top-left.
/// A pixel differs when any RGBA channel differs by more than `tolerance` (0-255), or it lies outside one image.
public func compareImages(_ a: CGImage, _ b: CGImage, tolerance: Int = 0) -> ImageDiff {
    let w = max(a.width, b.width), h = max(a.height, b.height)
    let pa = rgba(a, width: w, height: h), pb = rgba(b, width: w, height: h)
    var mask = [UInt8](repeating: 0, count: w * h * 4)
    var count = 0
    for p in 0..<(w * h) {
        let i = p * 4
        if abs(Int(pa[i]) - Int(pb[i])) > tolerance || abs(Int(pa[i + 1]) - Int(pb[i + 1])) > tolerance
            || abs(Int(pa[i + 2]) - Int(pb[i + 2])) > tolerance || abs(Int(pa[i + 3]) - Int(pb[i + 3])) > tolerance {
            count += 1
            mask[i] = 255; mask[i + 3] = 255
        }
    }
    let image = CGDataProvider(data: Data(mask) as CFData).flatMap {
        CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: $0, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)
    }
    return ImageDiff(width: w, height: h, differingPixels: count, mask: image)
}

private func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    buffer.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        // CoreGraphics origin is bottom-left; this keeps the image's top-left at the canvas top-left.
        ctx?.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
    }
    return buffer
}
