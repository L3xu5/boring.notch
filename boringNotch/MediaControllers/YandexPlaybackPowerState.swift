import Foundation
import IOKit.pwr_mgt

/// Yandex desktop 5.124.1 forwards PLAYER_STATE.isPlaying to Electron's
/// prevent-app-suspension blocker. Electron 38 / Chromium 140 owns that named
/// assertion in the browser main process. The caller verifies the Yandex PID.
/// This reads existing assertions only; it never creates or changes them.
public struct YandexPlaybackPowerState: Sendable {
    private var stability = YandexPlaybackPowerStability()

    public init() {}

    public mutating func reset() { stability.reset() }

    public mutating func read(processIdentifier: pid_t) -> Bool? {
        let observed = Self.rawState(processIdentifier: processIdentifier)
        return stability.observe(observed, processIdentifier: processIdentifier,
                                 at: ProcessInfo.processInfo.systemUptime)
    }

    static func rawState(processIdentifier: pid_t) -> Bool? {
        guard processIdentifier > 1 else { return nil }
        var copied: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&copied)
        let dictionary = copied?.takeRetainedValue()
        guard status == kIOReturnSuccess,
              let byProcess = dictionary as? [NSNumber: Any] else { return nil }
        return YandexPlaybackPowerClassifier.state(processIdentifier: processIdentifier,
                                                   assertionsByProcess: byProcess)
    }
}

/// The IOPM snapshot is complete only when its query succeeded. Missing own-PID entry
/// means no assertions; malformed own data remains unknown. Other PIDs are ignored.
enum YandexPlaybackPowerClassifier {
    static func state(processIdentifier: pid_t, assertionsByProcess: [NSNumber: Any]?) -> Bool? {
        guard processIdentifier > 1, let assertionsByProcess else { return nil }
        guard let own = assertionsByProcess[NSNumber(value: processIdentifier)] else { return false }
        guard let assertions = own as? [Any] else { return nil }
        var uncertain = false
        for value in assertions {
            guard let assertion = value as? [String: Any] else { uncertain = true; continue }
            switch active(assertion) {
            case true?: return true
            case nil: uncertain = true
            case false?: break
            }
        }
        return uncertain ? nil : false
    }

    private static func active(_ assertion: [String: Any]) -> Bool? {
        // These SDK dictionary keys are kIOPMAssertionNameKey / TypeKey / LevelKey.
        guard let name = assertion["AssertName"] as? String else { return nil }
        guard name == "Electron" else { return false }
        guard let type = assertion["AssertType"] as? String else { return nil }
        guard type == "NoIdleSleepAssertion" || type == "PreventUserIdleSystemSleep" else { return false }
        guard let level = assertion["AssertLevel"] as? NSNumber else { return nil }
        switch level.doubleValue {
        case 255: return true
        case 0: return false
        default: return nil
        }
    }
}

/// A release and replacement of the native blocker can span multiple asynchronous
/// tasks. Require consecutive, fresh absence observations before reporting paused.
struct YandexPlaybackPowerStability: Sendable {
    private let absenceInterval: TimeInterval
    private let maximumGap: TimeInterval
    private var processIdentifier: pid_t?
    private var lastObservation: TimeInterval?
    private var absentSince: TimeInterval?

    init(absenceInterval: TimeInterval = 2, maximumGap: TimeInterval = 2) {
        self.absenceInterval = absenceInterval
        self.maximumGap = maximumGap
    }

    mutating func reset() {
        processIdentifier = nil
        lastObservation = nil
        absentSince = nil
    }

    mutating func observe(_ observed: Bool?, processIdentifier: pid_t, at now: TimeInterval) -> Bool? {
        guard processIdentifier > 1, now.isFinite, now >= 0, let observed else { reset(); return nil }
        if self.processIdentifier != processIdentifier
            || lastObservation.map({ now < $0 || now - $0 > maximumGap }) == true {
            reset()
        }
        self.processIdentifier = processIdentifier
        lastObservation = now
        if observed { absentSince = nil; return true }
        if absentSince == nil { absentSince = now }
        guard let absentSince, now - absentSince >= absenceInterval else { return nil }
        return false
    }
}
