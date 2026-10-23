public enum ControlLayoutEditing {
    /// Assigning a control moves it rather than creating a duplicate. Clearing a
    /// slot never changes the other empty slots or overwrites another control.
    public static func assigning<Control: Equatable>(
        _ control: Control, to index: Int, in slots: [Control], empty: Control
    ) -> [Control]? {
        guard slots.indices.contains(index) else { return nil }
        var result = slots
        if control != empty {
            for other in result.indices where other != index && result[other] == control {
                result[other] = empty
            }
        }
        result[index] = control
        return result
    }

    public static func moving<Control>(from source: Int, to destination: Int, in slots: [Control]) -> [Control]? {
        guard slots.indices.contains(source), slots.indices.contains(destination) else { return nil }
        var result = slots
        result.swapAt(source, destination)
        return result
    }
}
