import AppKit
import SwiftUI

@MainActor
private enum ApplicationIconCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func image(for bundleID: String) -> NSImage? {
        if let image = images.object(forKey: bundleID as NSString) { return image.copy() as? NSImage }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let image = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage else { return nil }
        image.size = NSSize(width: 256, height: 256)
        images.setObject(image, forKey: bundleID as NSString, cost: 256 * 256 * 4)
        return image.copy() as? NSImage
    }
}

@MainActor
func AppIcon(for bundleID: String) -> Image {
    Image(nsImage: ApplicationIconCache.image(for: bundleID)
          ?? NSWorkspace.shared.icon(for: .applicationBundle))
}

@MainActor
func AppIconAsNSImage(for bundleID: String) -> NSImage? {
    ApplicationIconCache.image(for: bundleID)
}
