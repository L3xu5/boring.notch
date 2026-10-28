import AppKit
import Foundation
import IOKit.pwr_mgt

@main @MainActor private enum YandexPlaybackPowerTests {
    private static let mainPID: pid_t = 42
    private static var checks = 0
    private static func assertion(_ name: Any = "Electron", type: Any = "PreventUserIdleSystemSleep", level: Any = NSNumber(value: 255)) -> [String: Any] {
        ["AssertName": name, "AssertType": type, "AssertLevel": level]
    }
    private static func state(_ own: Any?, others: [NSNumber: Any] = [:]) -> Bool? {
        var snapshot = others
        if let own { snapshot[NSNumber(value: mainPID)] = own }
        return YandexPlaybackPowerClassifier.state(processIdentifier: mainPID, assertionsByProcess: snapshot)
    }
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard value() else { fatalError(message) }
    }

    static func main() throws {
        if CommandLine.arguments.contains("--native-self-test") { try nativeSelfTest(); return }
        if CommandLine.arguments.contains("--sample-yandex") { try sampleYandex(); return }
        classification()
        stability()
        print("Yandex playback power: \(checks) classification/stability checks passed (whole production provider; no OS query)")
    }

    private static func classification() {
        require(state([assertion()]) == true, "Canonical active blocker was lost")
        require(state([assertion(type: "NoIdleSleepAssertion")]) == true, "Chromium's legacy blocker type was lost")
        require(state([assertion(level: NSNumber(value: 0))]) == false, "An inactive assertion was treated as playing")
        require(state(nil) == false && state([]) == false, "Complete empty own-PID snapshot was not absent")
        require(state(nil, others: [NSNumber(value: 99): [assertion()]]) == false, "A different process supplied the Yandex playback flag")
        require(state([], others: [NSNumber(value: 99): NSNull()]) == false, "Malformed foreign data poisoned a valid own-PID snapshot")
        for name in ["electron", "Electron ", "Another app"] {
            require(state([assertion(name)]) == false, "The native assertion name was matched loosely")
        }
        require(state([assertion(type: "NoDisplaySleepAssertion")]) == false, "Unrelated blocker type was treated as player state")
        for value: Any in [NSNumber(value: 1), NSNumber(value: 255.5), NSNumber(value: Double.nan), "255"] {
            require(state([assertion(level: value)]) == nil, "Malformed level established a confident absence or playing state")
        }
        require(state([[:]]) == nil && state(NSNull()) == nil && state([NSNull()]) == nil, "Malformed own assertions were treated as absence")
        require(state([[:], assertion()]) == true, "A confirmed active own blocker did not win over an uncertain row")
        require(YandexPlaybackPowerClassifier.state(processIdentifier: mainPID, assertionsByProcess: nil) == nil, "A failed query was treated as absence")
        require(YandexPlaybackPowerClassifier.state(processIdentifier: 0, assertionsByProcess: [:]) == nil, "An invalid PID was treated as a known player")
    }

    private static func stability() {
        var policy = YandexPlaybackPowerStability()
        require(policy.observe(true, processIdentifier: mainPID, at: 0) == true, "Presence was delayed")
        require(policy.observe(false, processIdentifier: mainPID, at: 0.1) == nil, "A transient release immediately reported pause")
        require(policy.observe(false, processIdentifier: mainPID, at: 1.0) == nil, "Absence was confirmed before two seconds")
        require(policy.observe(false, processIdentifier: mainPID, at: 2.1) == false, "Stable absence did not report pause")
        require(policy.observe(true, processIdentifier: mainPID, at: 2.2) == true, "Playback presence did not recover immediately")
        require(policy.observe(false, processIdentifier: mainPID, at: 2.3) == nil, "Presence did not reset absence accumulation")
        require(policy.observe(nil, processIdentifier: mainPID, at: 3) == nil, "Unknown query result became a known state")
        require(policy.observe(false, processIdentifier: mainPID, at: 4) == nil, "Unknown did not reset the absence window")
        require(policy.observe(false, processIdentifier: mainPID, at: 5) == nil, "Unknown interval contributed to stable absence")
        require(policy.observe(false, processIdentifier: mainPID, at: 6) == false, "Fresh absence after unknown never settled")
        require(policy.observe(false, processIdentifier: 43, at: 6.1) == nil, "A different PID inherited absence from the previous process")
        require(policy.observe(false, processIdentifier: 43, at: 9) == nil, "A polling gap counted as continuous absence")
        require(policy.observe(false, processIdentifier: 43, at: 10) == nil, "Polling gap did not restart the window")
        require(policy.observe(false, processIdentifier: 43, at: 11) == false, "New samples after a gap did not settle")
        require(policy.observe(false, processIdentifier: 43, at: 10) == nil, "A backwards clock retained settled absence")
        require(policy.observe(false, processIdentifier: 43, at: 11) == nil, "Backwards clock did not restart the window")
        require(policy.observe(false, processIdentifier: 43, at: 12) == false, "Fresh samples after backwards clock did not settle")
        policy.reset()
        require(policy.observe(false, processIdentifier: 43, at: 12.1) == nil, "Explicit reset preserved settled absence")
        require(policy.observe(false, processIdentifier: 43, at: .nan) == nil, "Invalid clock data was accepted")
        require(policy.observe(false, processIdentifier: 43, at: 14) == nil, "Invalid clock data did not clear absence")
        require(policy.observe(true, processIdentifier: 44, at: 15) == true, "A new process's presence was not immediate")
    }

    private static func nativeSelfTest() throws {
        var assertionID: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Electron" as CFString, &assertionID)
        guard status == kIOReturnSuccess else { throw NSError(domain: "IOPM assertion self-test", code: Int(status)) }
        var released = false
        defer { if !released { IOPMAssertionRelease(assertionID) } }
        let pid = ProcessInfo.processInfo.processIdentifier
        var provider = YandexPlaybackPowerState()
        require(provider.read(processIdentifier: pid) == true, "Native own-PID blocker was not observed")
        require(IOPMAssertionRelease(assertionID) == kIOReturnSuccess, "Own test assertion could not be released")
        released = true
        require(provider.read(processIdentifier: pid) == nil, "Native absence bypassed the debounce")
        for _ in 0..<3 { Thread.sleep(forTimeInterval: 0.8); _ = provider.read(processIdentifier: pid) }
        require(provider.read(processIdentifier: pid) == false, "Released own-PID assertion did not settle to absent")
        print("Yandex playback power native self-test passed (only this process's assertion created/released)")
    }

    private static func sampleYandex() throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "ru.yandex.desktop.music").filter { !$0.isTerminated }
        guard applications.count == 1, let app = applications.first else {
            print("Yandex power sample: running main PID unavailable/ambiguous; state unknown")
            return
        }
        let pid = app.processIdentifier
        var provider = YandexPlaybackPowerState()
        var samples: [[String: Any]] = []
        for _ in 0..<4 {
            guard !app.isTerminated else { provider.reset(); break }
            let raw = YandexPlaybackPowerState.rawState(processIdentifier: pid)
            let settled = provider.read(processIdentifier: pid)
            samples.append(["raw": raw.map { $0 as Any } ?? NSNull(), "settled": settled.map { $0 as Any } ?? NSNull()])
            Thread.sleep(forTimeInterval: 0.8)
        }
        let data = try JSONSerialization.data(withJSONObject: ["mainPIDVerified": true, "samples": samples], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
