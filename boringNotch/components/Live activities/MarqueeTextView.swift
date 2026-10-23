import SwiftUI

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct MarqueeAnimationID: Equatable {
    let text: String
    let width: CGFloat
    let measuredWidth: CGFloat
    let reducedMotion: Bool
}

struct MarqueeText: View {
    @Binding var text: String
    let font: Font
    let nsFont: NSFont.TextStyle
    let textColor: Color
    let backgroundColor: Color
    let minDuration: Double
    let frameWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false
    @State private var textSize = CGSize.zero

    init(_ text: Binding<String>, font: Font = .body, nsFont: NSFont.TextStyle = .body,
         textColor: Color = .primary, backgroundColor: Color = .clear,
         minDuration: Double = 3, frameWidth: CGFloat = 200) {
        _text = text
        self.font = font
        self.nsFont = nsFont
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.minDuration = minDuration
        self.frameWidth = frameWidth
    }

    private var needsScrolling: Bool { textSize.width > max(0, frameWidth) + 1 }

    var body: some View {
        HStack(spacing: 20) {
            Text(text)
                .fixedSize(horizontal: true, vertical: false)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: SizePreferenceKey.self, value: geometry.size)
                })
            if needsScrolling && !reduceMotion {
                Text(text).fixedSize(horizontal: true, vertical: false).accessibilityHidden(true)
            }
        }
        .font(font)
        .foregroundStyle(textColor)
        .offset(x: animate ? -(textSize.width + 20) : 0)
        .animation(animate && !reduceMotion
                   ? .linear(duration: max(1, Double(textSize.width / 30))).delay(minDuration).repeatForever(autoreverses: false)
                   : nil, value: animate)
        .frame(width: max(0, frameWidth), alignment: .leading)
        .frame(height: max(textSize.height, NSFont.preferredFont(forTextStyle: nsFont).pointSize * 1.3))
        .clipped()
        .background(backgroundColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .help(text)
        .onPreferenceChange(SizePreferenceKey.self) { textSize = $0 }
        .task(id: MarqueeAnimationID(text: text, width: frameWidth, measuredWidth: textSize.width, reducedMotion: reduceMotion)) {
            animate = false
            guard needsScrolling, !reduceMotion else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            animate = true
        }
        .onDisappear { animate = false }
    }
}
