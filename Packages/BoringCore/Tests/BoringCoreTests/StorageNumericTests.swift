import Testing
@testable import BoringCore

struct StorageNumericTests {
    @Test func nonFiniteAndOversizedValuesCannotTrapLayoutConversion() {
        #expect(FiniteNumericConversion.integer(.nan) == 0)
        #expect(FiniteNumericConversion.integer(.infinity) == 0)
        #expect(FiniteNumericConversion.integer(.greatestFiniteMagnitude) == Int.max)
        #expect(FiniteNumericConversion.integer(-Double.greatestFiniteMagnitude) == Int.min)
        #expect(FiniteNumericConversion.evenInteger(Double.greatestFiniteMagnitude) == Int.max - 1)
        #expect(FiniteNumericConversion.evenInteger(3) == 4)
        #expect(FiniteNumericConversion.evenInteger(-3) == -4)
    }
}
