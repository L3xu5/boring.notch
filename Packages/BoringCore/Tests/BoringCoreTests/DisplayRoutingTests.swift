import Testing
@testable import BoringCore

@Suite("Display routing")
struct DisplayRoutingTests {
    private func route(_ ids: [String], preferred: String? = nil, active: String? = nil,
                       all: Bool = false, automatic: Bool = true) -> [String] {
        DisplayRoutingPolicy.desiredDisplayIDs(availableIDs: ids, preferredID: preferred, activeID: active,
                                               showOnAllDisplays: all, automaticallySwitchDisplay: automatic)
    }

    @Test func missingScreensAreSafe() { #expect(route([]) == []) }
    @Test func firstLaunchUsesActiveDisplay() { #expect(route(["a", "b"], active: "b", automatic: false) == ["b"]) }
    @Test func savedDisplayWins() { #expect(route(["a", "b"], preferred: "a", active: "b") == ["a"]) }
    @Test func disconnectedPreferenceCanHideTheNotch() { #expect(route(["b"], preferred: "a", active: "b", automatic: false) == []) }
    @Test func automaticFallbackUsesRemainingDisplay() { #expect(route(["b"], preferred: "a", active: "b") == ["b"]) }
    @Test func allDisplaysAreUniqueAndValid() { #expect(route(["a", "", "a", "b"], preferred: "a", all: true) == ["a", "b"]) }
    @Test func unknownActiveDisplayFallsBackSafely() { #expect(route(["a"], active: "missing") == ["a"]) }
}
