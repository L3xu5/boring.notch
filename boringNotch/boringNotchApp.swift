import Defaults
import Sparkle
import SwiftUI

@main
struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Default(.menubarIcon) private var showMenuBarIcon
    @Default(.boringShelf) private var shelfEnabled
    @Default(.enableLyrics) private var lyricsEnabled
    @AppStorage("firstLaunch") private var needsSetup = true
    private let updaterController: SPUStandardUpdaterController

    init() {
        if ApplicationLaunchOptions.isSnapshot {
            UserDefaults.standard.removePersistentDomain(forName: "local.boringnotch.preview")
        }
        if !ApplicationLaunchOptions.isSnapshot { ApplicationPreferencesMigration.run() }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: ApplicationLaunchOptions.startsAutomaticUpdates, updaterDelegate: nil, userDriverDelegate: nil
        )
        SettingsWindowController.shared.setUpdaterController(updaterController)
    }

    var body: some Scene {
        MenuBarExtra("Boring Notch", systemImage: "sparkle", isInserted: ApplicationLaunchOptions.isSnapshot ? .constant(false) : $showMenuBarIcon) {
            if needsSetup {
                Button("Finish Setup…", systemImage: "checklist") { appDelegate.resumeOnboarding() }
                Divider()
            }
            Button("Open Music", systemImage: "music.note") { appDelegate.open(.home) }
            Button("Open Shelf", systemImage: "tray") { appDelegate.open(.shelf) }
                .disabled(!shelfEnabled)
            Button("Open Lyrics", systemImage: "quote.bubble") { appDelegate.open(.lyrics) }
                .disabled(!lyricsEnabled)
            Divider()
            Button("Settings…", systemImage: "gearshape") { SettingsWindowController.shared.showWindow() }
                .keyboardShortcut(",", modifiers: .command)
            CheckForUpdatesView(updater: updaterController.updater)
            Divider()
            Button("Restart Boring Notch") { ApplicationRelauncher.restart() }
            Button("Quit Boring Notch", role: .destructive) { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var runtime = ApplicationRuntime()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ApplicationLaunchOptions.isSnapshot {
            Task { @MainActor in await DebugUIRenderer.run() }
            return
        }
        #endif
        runtime.start()
    }
    func applicationWillTerminate(_ notification: Notification) {
        if !ApplicationLaunchOptions.isSnapshot { runtime.stop() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !ApplicationLaunchOptions.isSnapshot {
            if BoringViewCoordinator.shared.firstLaunch { runtime.resumeOnboarding() }
            else { SettingsWindowController.shared.showWindow() }
        }
        return false
    }

    func open(_ view: NotchViews) { runtime.open(view) }
    func resumeOnboarding() { runtime.resumeOnboarding() }
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")
}
