import AppKit
import BoringCore
import SwiftUI

private enum ArtworkColorSampler {
    /// Work is bounded by the thumbnail size, rather than the original artwork's megapixels.
    static func average(_ image: NSImage) -> RGBAColor? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width > 0, source.height > 0 else { return nil }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return rendered ? RGBAColor.averagePremultipliedRGBA8(pixels) : nil
    }
}

extension NSImage {
    func averageColor(completion: @escaping (NSColor?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let color = ArtworkColorSampler.average(self)?.ensuringMinimumLuminance(0.5)
            let result = color.map {
                NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func getBrightness() -> CGFloat {
        CGFloat(ArtworkColorSampler.average(self)?.luminance ?? 0)
    }
}

extension Color {
    func ensureMinimumBrightness(factor: CGFloat) -> Color {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return self }
        let adjusted = RGBAColor(
            red: color.redComponent, green: color.greenComponent,
            blue: color.blueComponent, alpha: color.alphaComponent
        ).ensuringMinimumLuminance(Double(factor))
        return Color(red: adjusted.red, green: adjusted.green, blue: adjusted.blue, opacity: adjusted.alpha)
    }
}
