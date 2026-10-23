import Foundation

/// Color arithmetic independent of AppKit, pixel format and the rendering thread.
public struct RGBAColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.component(red)
        self.green = Self.component(green)
        self.blue = Self.component(blue)
        self.alpha = Self.component(alpha)
    }

    public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    /// Mix toward white only when necessary. Scaling channels alone clips saturated colors
    /// before they reach the requested luminance and divides by zero for black.
    public func ensuringMinimumLuminance(_ minimum: Double) -> Self {
        guard minimum.isFinite, (0...1).contains(minimum), luminance < minimum else { return self }
        let fraction = (minimum - luminance) / (1 - luminance)
        return Self(
            red: red + (1 - red) * fraction,
            green: green + (1 - green) * fraction,
            blue: blue + (1 - blue) * fraction,
            alpha: alpha
        )
    }

    /// Average a packed RGBA8 bitmap whose RGB channels are premultiplied by alpha.
    /// Fully transparent pixels do not pull the result toward black.
    public static func averagePremultipliedRGBA8(_ pixels: [UInt8]) -> Self? {
        guard !pixels.isEmpty, pixels.count.isMultiple(of: 4) else { return nil }
        var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            red += Double(pixels[index])
            green += Double(pixels[index + 1])
            blue += Double(pixels[index + 2])
            alpha += Double(pixels[index + 3])
        }
        guard alpha > 0 else { return nil }
        return Self(red: red / alpha, green: green / alpha, blue: blue / alpha)
    }

    private static func component(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
