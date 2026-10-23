import AppKit

@MainActor
enum ApplicationRelauncher {
    static func restart() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        // Relaunch this exact bundle, even when a development build shares its identifier
        // with the installed release. Keep the current app alive if launching fails.
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    NSApp.presentError(error)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
