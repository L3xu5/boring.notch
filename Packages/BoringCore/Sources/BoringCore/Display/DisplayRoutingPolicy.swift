import Foundation

/// Pure display selection shared by startup, hot-plug and display preference changes.
public enum DisplayRoutingPolicy {
    public static func desiredDisplayIDs(
        availableIDs: [String], preferredID: String?, activeID: String?,
        showOnAllDisplays: Bool, automaticallySwitchDisplay: Bool
    ) -> [String] {
        var seen = Set<String>()
        let available = availableIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !available.isEmpty else { return [] }
        if showOnAllDisplays { return available }
        if let preferredID, available.contains(preferredID) { return [preferredID] }
        // A missing saved display may intentionally hide the notch until that display returns.
        if let preferredID, !preferredID.isEmpty, !automaticallySwitchDisplay { return [] }
        if let activeID, available.contains(activeID) { return [activeID] }
        return [available[0]]
    }
}
