import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private var finished = false

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = String(localized: "Welcome to Boring Notch")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("BoringNotchOnboarding")
        window.contentView = NSHostingView(rootView: OnboardingView(
            onFinish: { [weak self] in self?.finish(openSettings: false) },
            onOpenSettings: { [weak self] in self?.finish(openSettings: true) }
        ))
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window else { return }
        ApplicationActivationPolicy.present(window)
    }

    private func finish(openSettings: Bool) {
        close()
        if openSettings { SettingsWindowController.shared.showWindow() }
    }

    override func close() {
        guard !finished else { return }
        finished = true
        let closingWindow = window
        closingWindow?.contentView = nil
        super.close()
        ApplicationActivationPolicy.restore(excluding: closingWindow)
        onClose()
    }

    func windowWillClose(_ notification: Notification) {
        if !finished { close() }
    }
}
