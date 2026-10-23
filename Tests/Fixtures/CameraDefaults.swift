import Combine

/// Interface-only in-memory replacement for Defaults in the whole-VM regression.
/// No UserDefaults suite or installed app profile is opened by this test module.
public enum Defaults {
    open class Keys {
        public init() {}
    }
    public final class Key<Value>: Keys {
        public let name: String
        public let initialValue: Value
        public init(_ name: String, default initialValue: Value) {
            self.name = name
            self.initialValue = initialValue
            super.init()
        }
    }
    public struct Change<Value> {
        public let newValue: Value
        public init(newValue: Value) { self.newValue = newValue }
    }
    private static var values: [String: Any] = [:]
    public static subscript<Value>(_ key: Key<Value>) -> Value {
        get { values[key.name] as? Value ?? key.initialValue }
        set { values[key.name] = newValue }
    }
    public static func publisher<Value>(_ key: Key<Value>) -> AnyPublisher<Change<Value>, Never> {
        Just(Change(newValue: Defaults[key])).eraseToAnyPublisher()
    }
}
