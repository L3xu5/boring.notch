import SwiftUI

/// Hover opens the notch without making its panel key. Its controls must still
/// receive the first mouse event instead of using that click only for focus.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
