import Foundation
import ObjectiveC

/// A stable Objective-C association key. The stored value retains its key token, so a
/// short-lived helper cannot leave an address that a later helper accidentally reuses.
public struct AssociatedObject<Value: AnyObject> {
    private final class Key: NSObject {}
    private final class StoredValue: NSObject {
        let key: Key
        let value: Value
        init(key: Key, value: Value) { self.key = key; self.value = value }
    }
    private let key = Key()
    public init() {}

    public subscript<Owner: AnyObject>(_ owner: Owner) -> Value? {
        get {
            (objc_getAssociatedObject(owner, Unmanaged.passUnretained(key).toOpaque()) as? StoredValue)?.value
        }
        nonmutating set {
            let stored = newValue.map { StoredValue(key: key, value: $0) }
            objc_setAssociatedObject(owner, Unmanaged.passUnretained(key).toOpaque(), stored,
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
