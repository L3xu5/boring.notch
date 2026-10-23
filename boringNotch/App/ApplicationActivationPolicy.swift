import AppKit

@MainActor
enum ApplicationActivationPolicy {
    static func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func restore(excluding excluded: NSWindow? = nil) {
        let hasAuxiliaryWindow = NSApp.windows.contains { window in
            window !== excluded && window.isVisible && window.canBecomeKey
                && !(window is BoringNotchSkyLightWindow) && !(window is BoringNotchWindow)
        }
        NSApp.setActivationPolicy(hasAuxiliaryWindow ? .regular : .accessory)
        if !hasAuxiliaryWindow { NSApp.deactivate() }
    }
}
