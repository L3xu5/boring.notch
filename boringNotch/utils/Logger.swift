import Darwin
import Foundation
import OSLog
import SwiftUI

enum LogCategory: String, Sendable {
    case lifecycle, memory, performance, ui, network, error, warning, success, debug
}

/// Unified logging keeps diagnostics available without printing user metadata to stdout.
struct AppLogger {
    static func log(_ message: String, category: LogCategory, file: String = #fileID,
                    function: String = #function, line: Int = #line) {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "theboringteam.boringnotch",
                                  category: category.rawValue)
        let location = "\(file):\(line) \(function)"
        switch category {
        case .error:
            logger.error("\(location, privacy: .public) \(message, privacy: .private)")
        case .warning:
            logger.warning("\(location, privacy: .public) \(message, privacy: .private)")
        case .success:
            logger.notice("\(location, privacy: .public) \(message, privacy: .private)")
        default:
            logger.debug("\(location, privacy: .public) \(message, privacy: .private)")
        }
    }

    static func trackMemory(file: String = #fileID, function: String = #function, line: Int = #line) {
        #if DEBUG
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            log(String(format: "Resident memory %.2f MB", Double(info.resident_size) / 1_048_576),
                category: .memory, file: file, function: function, line: line)
        }
        #endif
    }
}

extension View {
    func trackLifecycle(_ identifier: String) -> some View { modifier(ViewLifecycleTracker(identifier: identifier)) }
}

struct ViewLifecycleTracker: ViewModifier {
    let identifier: String
    func body(content: Content) -> some View {
        #if DEBUG
        content.onAppear { AppLogger.log("\(identifier) appeared", category: .lifecycle) }
            .onDisappear { AppLogger.log("\(identifier) disappeared", category: .lifecycle) }
        #else
        content
        #endif
    }
}
