import Foundation

public struct MediaKeyRecoverySnapshot: Sendable {
    public var systemOwner: String?
    public var systemIsPlaying: Bool?
    public var foreignActivity: Date?
    public var yandexIsPlaying: Bool?
    public var accessibilityObservedAt: Date?
    public var foregroundApp: String?
    public var capturedAt: Date

    public init(
        systemOwner: String? = nil,
        systemIsPlaying: Bool? = nil,
        foreignActivity: Date? = nil,
        yandexIsPlaying: Bool? = nil,
        accessibilityObservedAt: Date? = nil,
        foregroundApp: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.systemOwner = systemOwner
        self.systemIsPlaying = systemIsPlaying
        self.foreignActivity = foreignActivity
        self.yandexIsPlaying = yandexIsPlaying
        self.accessibilityObservedAt = accessibilityObservedAt
        self.foregroundApp = foregroundApp
        self.capturedAt = capturedAt
    }
}

/// Decides whether a forwarded media key left a demonstrably stale native session
/// unchanged. Missing playback or activity evidence leaves control with macOS.
public enum MediaKeyRecoveryPolicy {
    public static let yandexBundleIdentifier = "ru.yandex.desktop.music"
    private static let foreignInactivity: TimeInterval = 10
    private static let accessibilityFreshness: TimeInterval = 2.5
    private static let responseWindow: TimeInterval = 5

    public static func isCandidate(
        _ snapshot: MediaKeyRecoverySnapshot,
        at date: Date,
        recentlyRecoveredYandex: Bool = false
    ) -> Bool {
        guard let owner = snapshot.systemOwner,
              !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              owner != yandexBundleIdentifier,
              snapshot.systemIsPlaying == false,
              snapshot.foregroundApp != owner,
              snapshot.capturedAt <= date,
              let activity = snapshot.foreignActivity,
              date.timeIntervalSince(activity) >= foreignInactivity,
              let observed = snapshot.accessibilityObservedAt,
              observed <= snapshot.capturedAt,
              date.timeIntervalSince(observed) >= 0,
              date.timeIntervalSince(observed) <= accessibilityFreshness,
              let yandexIsPlaying = snapshot.yandexIsPlaying else { return false }

        return yandexIsPlaying
            || snapshot.foregroundApp == yandexBundleIdentifier
            || recentlyRecoveredYandex
    }

    public static func shouldRecover(
        before: MediaKeyRecoverySnapshot,
        after: MediaKeyRecoverySnapshot,
        at date: Date,
        recentlyRecoveredYandex: Bool = false
    ) -> Bool {
        guard before.capturedAt < after.capturedAt,
              after.capturedAt <= date,
              date.timeIntervalSince(before.capturedAt) <= responseWindow,
              isCandidate(before, at: before.capturedAt, recentlyRecoveredYandex: recentlyRecoveredYandex),
              isCandidate(after, at: date, recentlyRecoveredYandex: recentlyRecoveredYandex),
              before.systemOwner == after.systemOwner,
              before.foreignActivity == after.foreignActivity,
              before.yandexIsPlaying == after.yandexIsPlaying,
              before.foregroundApp == after.foregroundApp,
              let earlierObservation = before.accessibilityObservedAt,
              let laterObservation = after.accessibilityObservedAt,
              laterObservation > earlierObservation,
              laterObservation > before.capturedAt else { return false }

        return true
    }
}
