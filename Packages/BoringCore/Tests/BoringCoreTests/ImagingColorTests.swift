import Testing
@testable import BoringCore

@Suite("Artwork color arithmetic")
struct ImagingColorTests {
    @Test func blackCanBeBrightenedWithoutNaN() {
        let result = RGBAColor(red: 0, green: 0, blue: 0).ensuringMinimumLuminance(0.5)
        #expect(result == RGBAColor(red: 0.5, green: 0.5, blue: 0.5))
        #expect(result.luminance.isFinite)
    }

    @Test func brightColorsAreNotDimmed() {
        let color = RGBAColor(red: 0.8, green: 0.9, blue: 0.7, alpha: 0.4)
        #expect(color.ensuringMinimumLuminance(0.3) == color)
    }

    @Test func saturatedColorsReachTheMinimum() {
        let result = RGBAColor(red: 1, green: 0, blue: 0).ensuringMinimumLuminance(0.6)
        #expect(abs(result.luminance - 0.6) < 0.000_001)
        #expect(result.red == 1)
    }

    @Test func invalidThresholdsAndChannelsAreSafe() {
        let color = RGBAColor(red: .nan, green: .infinity, blue: -1, alpha: 2)
        #expect(color == RGBAColor(red: 0, green: 0, blue: 0, alpha: 1))
        #expect(color.ensuringMinimumLuminance(.nan) == color)
        #expect(color.ensuringMinimumLuminance(2) == color)
    }

    @Test func bitmapByteOrderAndTransparencyAreExplicit() {
        #expect(RGBAColor.averagePremultipliedRGBA8([255, 0, 0, 255]) == RGBAColor(red: 1, green: 0, blue: 0))
        #expect(RGBAColor.averagePremultipliedRGBA8([128, 0, 0, 128, 0, 0, 0, 0]) == RGBAColor(red: 1, green: 0, blue: 0))
        #expect(RGBAColor.averagePremultipliedRGBA8([0, 0, 0, 0]) == nil)
        #expect(RGBAColor.averagePremultipliedRGBA8([]) == nil)
        #expect(RGBAColor.averagePremultipliedRGBA8([1, 2, 3]) == nil)
    }
}
