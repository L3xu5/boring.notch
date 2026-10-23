import Testing
@testable import BoringCore

@Test func assigningAControlPreservesOtherCustomizedSlots() {
    let original = ["like", "previous", "play", "next", "empty"]
    #expect(ControlLayoutEditing.assigning("like", to: 4, in: original, empty: "empty") == ["empty", "previous", "play", "next", "like"])
    #expect(ControlLayoutEditing.assigning("empty", to: 2, in: original, empty: "empty") == ["like", "previous", "empty", "next", "empty"])
    #expect(ControlLayoutEditing.assigning("play", to: -1, in: original, empty: "empty") == nil)
    #expect(ControlLayoutEditing.assigning("play", to: 5, in: original, empty: "empty") == nil)
}

@Test func movingControlsSwapsOnlyTheRequestedSlots() {
    let original = ["like", "previous", "play", "next", "dislike"]
    #expect(ControlLayoutEditing.moving(from: 0, to: 4, in: original) == ["dislike", "previous", "play", "next", "like"])
    #expect(ControlLayoutEditing.moving(from: 1, to: 1, in: original) == original)
    #expect(ControlLayoutEditing.moving(from: 5, to: 0, in: original) == nil)
}
