import Foundation

enum ApplicationLaunchOptions {
    static var isSnapshot: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-snapshot")
            && Bundle.main.bundleIdentifier == "local.boringnotch.preview"
        #else
        false
        #endif
    }

    static var startsAutomaticUpdates: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
