import Combine
import Defaults
import Foundation
import MacroVisionKit

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()
    @Published private(set) var fullscreenStatus: [String: Bool] = [:]
    private var monitorTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var spaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo] = []
    private var started = false
    private var suspended = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        Defaults.publisher(.hideNotchOption).receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.configureMonitoring()
        }.store(in: &subscriptions)
        MusicManager.shared.$bundleIdentifier.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.rebuildStatus()
        }.store(in: &subscriptions)
        configureMonitoring()
    }

    func stop() {
        started = false
        monitorTask?.cancel()
        monitorTask = nil
        subscriptions.removeAll()
        spaces.removeAll()
        if !fullscreenStatus.isEmpty { fullscreenStatus = [:] }
    }

    func setSuspended(_ value: Bool) {
        suspended = value
        configureMonitoring()
    }

    private func configureMonitoring() {
        guard started, !suspended, Defaults[.hideNotchOption] != .never else {
            monitorTask?.cancel()
            monitorTask = nil
            spaces.removeAll()
            rebuildStatus()
            return
        }
        if monitorTask == nil {
            monitorTask = Task { @MainActor [weak self] in
                let stream = await FullScreenMonitor.shared.spaceChanges()
                for await spaces in stream {
                    guard !Task.isCancelled else { return }
                    self?.spaces = spaces
                    self?.rebuildStatus()
                }
            }
        }
        rebuildStatus()
    }

    private func rebuildStatus() {
        var next: [String: Bool] = [:]
        if started && !suspended {
            let option = Defaults[.hideNotchOption]
            let source = MusicManager.shared.bundleIdentifier
            for space in spaces {
                guard let id = space.screenUUID else { continue }
                let matches: Bool
                switch option {
                case .always: matches = true
                case .nowPlayingOnly: matches = source.map { space.runningApps.contains($0) } ?? false
                case .never: matches = false
                }
                next[id] = matches
            }
        }
        if next != fullscreenStatus { fullscreenStatus = next }
    }

    deinit { monitorTask?.cancel() }
}
