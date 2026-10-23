import Foundation
import Testing
@testable import BoringCore

@Test func settingsDestinationsHaveStableUniqueIdentity() {
    let first = SettingsDestination.allCases.map(\.id)
    #expect(first == SettingsDestination.allCases.map(\.id))
    #expect(Set(first).count == first.count)
    #expect(Set(SettingsDestination.allCases.map(\.group)) == Set(SettingsGroup.allCases))
}

@Test func settingsSearchFindsFeaturesWithoutChangingDestinationIDs() {
    #expect(SettingsDestination.media.matches("yAnDeX lyrics"))
    #expect(SettingsDestination.hud.matches("accessibility brightness"))
    #expect(SettingsDestination.general.matches("display height"))
    #expect(SettingsDestination.about.matches("build update"))
    #expect(SettingsDestination.general.matches("Preferred display"))
    #expect(SettingsDestination.appearance.matches("Progress color"))
    #expect(SettingsDestination.media.matches("Enable lyrics"))
    #expect(SettingsDestination.media.matches("lyrics delay"))
    #expect(SettingsDestination.media.matches("МЕДИА", localizedText: "Медиа. Тексты песен и плеер"))
    #expect(SettingsDestination.media.matches("Yandex текст", localizedText: "Медиа. Тексты песен и плеер"))
    #expect(SettingsDestination.allCases.allSatisfy { $0.matches("  ") })
    #expect(!SettingsDestination.calendar.matches("OAuth"))
}

@Test func visualizerInputRequiresAnAbsoluteWebURL() {
    #expect(SettingsInputValidation.visualizerURL(" https://example.com/animation.json ")?.host == "example.com")
    #expect(SettingsInputValidation.visualizerURL("http://localhost:8000/music.json") != nil)
    for input in ["", "music.json", "javascript:alert(1)", "file:///tmp/a.json", "https://", "http://[::1", "https://user:secret@example.com/a.json"] {
        #expect(SettingsInputValidation.visualizerURL(input) == nil)
    }
}
