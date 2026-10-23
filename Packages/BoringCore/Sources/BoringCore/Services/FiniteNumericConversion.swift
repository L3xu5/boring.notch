public enum FiniteNumericConversion {
    /// Layout and hardware inputs can contain NaN/Infinity. Swift's integer conversion traps
    /// for those values and for values outside Int's bounds, so normalize at the boundary.
    public static func integer(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }
    public static func evenInteger(_ value: Double) -> Int {
        let integer = integer(value.rounded())
        if integer == Int.max { return Int.max - 1 }
        return integer + integer % 2
    }
}
