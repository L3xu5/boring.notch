//
//  SettingsWindowController.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-14.
//

import AppKit
import SwiftUI
import Defaults
import Sparkle

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private var updaterController: SPUStandardUpdaterController?
    private var hasBeenShown = false
    
    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        super.init(window: window)
        
        setupWindow()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setUpdaterController(_ controller: SPUStandardUpdaterController) {
        guard updaterController !== controller else { return }
        self.updaterController = controller
        // Recreate the content view with the proper updater controller
        setupWindow()
    }
    
    private func setupWindow() {
        guard let window = window else { return }
        
        window.title = NSLocalizedString("Boring Notch Settings", comment: "Settings window title")
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        
        // Make it behave like a regular app window with proper Spaces support
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
        
        // Ensure proper window behavior
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = false
        
        // Configure window to be a standard document-style window
        window.isRestorable = true
        window.identifier = NSUserInterfaceItemIdentifier("BoringNotchSettingsWindow")
        window.minSize = NSSize(width: 680, height: 560)
        window.setFrameAutosaveName("BoringNotchSettingsWindow")
        
        // Create the SwiftUI content
        let settingsView = SettingsView(updaterController: updaterController)
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.sizingOptions = [.minSize]
        window.contentView = hostingView
        
        // Handle window closing
        window.delegate = self
    }
    
    func showWindow() {
        if window?.contentView == nil { setupWindow() }
        guard let window else { return }
        if !window.isVisible && !hasBeenShown && UserDefaults.standard.string(forKey: "NSWindow Frame BoringNotchSettingsWindow") == nil {
            window.center()
        }
        hasBeenShown = true
        ApplicationActivationPolicy.present(window)
        DispatchQueue.main.async { [weak self] in self?.window?.makeKeyAndOrderFront(nil) }
    }

    override func close() {
        super.close()
        relinquishFocus()
    }
    
    private func relinquishFocus() {
        window?.orderOut(nil)
        // Closing Settings releases its observation tasks, animation previews,
        // and unsaved token-entry drafts. Navigation is restored from AppStorage.
        window?.contentView = nil
        
        // Set app back to accessory mode immediately
        ApplicationActivationPolicy.restore(excluding: window)
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        relinquishFocus()
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        // Presentation goes through the shared auxiliary-window activation policy.
    }
    
    func windowDidResignKey(_ notification: Notification) {
    }
    
}
