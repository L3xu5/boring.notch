import Foundation

@MainActor
final class NotchSpaceManager {
    static let shared = NotchSpaceManager()
    let notchSpace = CGSSpace(level: 2147483647)
    private init() {}
    func shutdown() { notchSpace.destroy() }
}
