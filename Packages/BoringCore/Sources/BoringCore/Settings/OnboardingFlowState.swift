import Foundation

public enum SetupStage: String, CaseIterable, Sendable {
    case welcome, musicSource, features, accessibility, camera, calendar, reminders, finished
}

/// Permission results may arrive after Skip, Back, or window dismissal. Only the
/// request belonging to the current stage may advance the flow.
public struct OnboardingFlowState: Sendable {
    public private(set) var stage: SetupStage = .welcome
    public private(set) var pendingRequest: UUID?

    public init() {}

    public mutating func navigate(to stage: SetupStage) {
        pendingRequest = nil
        self.stage = stage
    }

    public mutating func beginRequest() -> UUID? {
        guard pendingRequest == nil else { return nil }
        let id = UUID()
        pendingRequest = id
        return id
    }

    @discardableResult
    public mutating func finishRequest(_ id: UUID, from stage: SetupStage, advancingTo next: SetupStage?) -> Bool {
        guard self.stage == stage, pendingRequest == id else { return false }
        pendingRequest = nil
        if let next { self.stage = next }
        return true
    }
}
