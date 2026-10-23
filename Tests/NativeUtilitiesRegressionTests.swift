import Foundation

private final class Value: NSObject {
    let name: String
    init(_ name: String) { self.name = name }
}

@main
struct NativeUtilitiesRegressionTests {
    static func main() {
        let owner = NSObject()
        let first = AssociatedObject<Value>()
        let second = AssociatedObject<Value>()
        first[owner] = Value("first")
        second[owner] = Value("second")
        precondition(first[owner]?.name == "first")
        precondition(second[owner]?.name == "second")
        first[owner] = nil
        precondition(first[owner] == nil && second[owner]?.name == "second")

        // An expired helper must not leave an address that a new key can reuse.
        autoreleasepool {
            let expired = AssociatedObject<Value>()
            expired[owner] = Value("expired")
        }
        for _ in 0..<1000 {
            let fresh = AssociatedObject<Value>()
            precondition(fresh[owner] == nil)
        }

        weak var retained: Value?
        autoreleasepool {
            let temporaryOwner = NSObject()
            let value = Value("owned")
            retained = value
            first[temporaryOwner] = value
            precondition(retained != nil)
        }
        precondition(retained == nil)
        print("Native association key isolation, short-lived key safety, clearing and owner cleanup passed")
    }
}
