#if DEBUG
import AppKit
import BoringCore
import Defaults
import Sparkle
import SwiftUI

private final class OffscreenPreviewWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var occlusionState: NSWindow.OcclusionState { [.visible] }
}

/// Developer-only visual QA. The launcher must use a distinct bundle identifier, so neither
/// settings nor app services from the installed release participate in the snapshot process.
@MainActor
enum DebugUIRenderer {
    static func run() async {
        guard ApplicationLaunchOptions.isSnapshot,
              let output = ApplicationLaunchOptions.value(after: "--snapshot-output") else { NSApp.terminate(nil); return }
        do {
            let destination = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let page = ApplicationLaunchOptions.value(after: "--snapshot-page") ?? "general"
            let setup = page.hasPrefix("onboarding")
            let width = Double(ApplicationLaunchOptions.value(after: "--snapshot-width") ?? (setup ? "460" : "820")) ?? 820
            let height = Double(ApplicationLaunchOptions.value(after: "--snapshot-height") ?? (setup ? "640" : "680")) ?? 680
            let dark = ApplicationLaunchOptions.value(after: "--snapshot-appearance") == "dark"
            UserDefaults.standard.set(false, forKey: "firstLaunch")
            BoringViewCoordinator.shared.helloAnimationRunning = false
            Defaults[.hudReplacement] = false
            Defaults[.showMirror] = false
            Defaults[.showCalendar] = false
            Defaults[.mediaController] = .yandexMusic
            UserDefaults.standard.set(page, forKey: "settings.destination")
            if page == "media" || page == "notch" {
                let music = MusicManager.shared
                music.songTitle = "Night Drive"
                music.artistName = "Boring Notch"
                music.album = "A quiet evening"
                music.songDuration = 210
                music.elapsedTime = 75
                music.timestampDate = Date()
                music.playbackRate = 1
                music.isPlaying = true
                music.canFavoriteTrack = true
                music.canDislikeTrack = true
                music.volume = 0.64
                music.volumeControlSupported = true
                music.albumArt = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Demo artwork") ?? NSImage(size: .init(width: 256, height: 256))
                music.avgColor = .systemTeal
            }
            let host: NSView
            if setup {
                let stage: SetupStage = page == "onboarding-source" ? .musicSource
                    : (page == "onboarding-permission" ? .accessibility : .welcome)
                host = makeHost(OnboardingView(initialStage: stage, onFinish: {}, onOpenSettings: {}))
            } else if page == "notch" {
                let model = BoringViewModel(screenUUID: NSScreen.main?.displayUUID)
                model.open()
                model.keyboardInteractionActive = true
                host = makeHost(ContentView().environmentObject(model))
            } else {
                let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
                host = makeHost(SettingsView(updaterController: updater))
            }
            let window = OffscreenPreviewWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
                                                styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.toolbarStyle = .unified
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderBack(nil)
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
            window.setContentSize(NSSize(width: width, height: height))
            host.setFrameOrigin(.zero)
            host.setFrameSize(NSSize(width: width, height: height))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(650))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let diagnostics: [String: Any] = [
                "page": page,
                "requestedSize": [width, height],
                "hostFrame": NSStringFromRect(host.frame),
                "hostBounds": NSStringFromRect(host.bounds),
                "viewTree": describe(host),
                "accessibility": accessibilityLabels(host),
            ]
            let diagnosticData = try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
            try diagnosticData.write(to: destination.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw SnapshotError.render }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError.render }
            try png.write(to: destination, options: .atomic)
            window.contentView = nil
            window.close()
            NSApp.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("UI snapshot failed: \(error)\n".utf8))
            NSApp.terminate(nil)
        }
    }

    private static func describe(_ view: NSView, depth: Int = 0) -> [String: Any] {
        var value: [String: Any] = [
            "type": NSStringFromClass(type(of: view)), "frame": NSStringFromRect(view.frame),
            "bounds": NSStringFromRect(view.bounds), "hidden": view.isHidden,
        ]
        if let table = view as? NSTableView {
            value["rows"] = table.numberOfRows
            value["columns"] = table.numberOfColumns
            for row in 0..<min(table.numberOfRows, 40) {
                for column in 0..<table.numberOfColumns { _ = table.view(atColumn: column, row: row, makeIfNecessary: true) }
            }
            table.displayIfNeeded()
        }
        if depth < 24 { value["children"] = view.subviews.map { describe($0, depth: depth + 1) } }
        return value
    }

    private static func accessibilityLabels(_ root: Any) -> [String] {
        var labels: [String] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 30, seen.count < 2000, let element = value as? any NSAccessibilityProtocol else { return }
            let identity = ObjectIdentifier(element as AnyObject)
            guard seen.insert(identity).inserted else { return }
            if let label = element.accessibilityLabel(), !label.isEmpty { labels.append(label) }
            if element.accessibilityRole()?.rawValue == "AXStaticText",
               let text = element.accessibilityValue() as? String, !text.isEmpty { labels.append(text) }
            for child in element.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return labels
    }

    private static func makeHost<Content: View>(_ content: Content) -> NSView {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        return host
    }

    private enum SnapshotError: Error { case render }
}
#endif
