import Defaults

@MainActor
enum ApplicationPreferencesMigration {
    static func run() {
        if !Defaults[.didMigrateControlSlotsV1] {
            let oldDefault: [MusicControlButton] = [.none, .previous, .playPause, .next, .none]
            if Defaults[.musicControlSlots] == oldDefault { Defaults[.musicControlSlots] = MusicControlButton.defaultLayout }
            Defaults[.didMigrateControlSlotsV1] = true
        }
        if !Defaults[.didMigrateControlSlotsV2] {
            var slots = Defaults[.musicControlSlots]
            if !slots.contains(.dislike), let empty = slots.firstIndex(of: .none) {
                slots[empty] = .dislike
                Defaults[.musicControlSlots] = slots
            }
            Defaults[.didMigrateControlSlotsV2] = true
        }
    }
}
