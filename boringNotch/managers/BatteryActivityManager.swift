import Foundation
import IOKit.ps
import BoringCore

/// Delivers coherent current-state changes immediately on the main actor. Transitions are
/// not queued seconds behind reality, and subscriber tokens survive unrelated removals.
@MainActor
final class BatteryActivityManager: NSObject {
    static let shared = BatteryActivityManager()
    var onBatteryLevelChange: ((Float) -> Void)?
    var onMaxCapacityChange: ((Float) -> Void)?
    var onPowerModeChange: ((Bool) -> Void)?
    var onPowerSourceChange: ((Bool) -> Void)?
    var onChargingChange: ((Bool) -> Void)?
    var onTimeToFullChargeChange: ((Int) -> Void)?
    private let observers = EventObservers<BatteryEvent>()
    private var previousBatteryInfo: BatteryInfo?
    private var batterySource: CFRunLoopSource?
    private var powerObserver: NSObjectProtocol?

    enum BatteryEvent: Sendable {
        case powerSourceChanged(isPluggedIn: Bool)
        case batteryLevelChanged(level: Float)
        case lowPowerModeChanged(isEnabled: Bool)
        case isChargingChanged(isCharging: Bool)
        case timeToFullChargeChanged(time: Int)
        case maxCapacityChanged(capacity: Float)
        case error(description: String)
    }
    private override init() {
        super.init()
        batterySource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let manager = Unmanaged<BatteryActivityManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak manager] in manager?.notifyBatteryChanges() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let batterySource { CFRunLoopAddSource(CFRunLoopGetMain(), batterySource, .commonModes) }
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.notifyBatteryChanges() }
        }
    }
    func initializeBatteryInfo() -> BatteryInfo {
        let info = readBatteryInfo() ?? .unavailable
        previousBatteryInfo = info
        return info
    }
    func addObserver(_ observer: @escaping @MainActor @Sendable (BatteryEvent) -> Void) -> UUID { observers.add(observer) }
    func removeObserver(byId id: UUID) { observers.remove(id) }
    private func notifyBatteryChanges() {
        guard let current = readBatteryInfo() else { return }
        let old = previousBatteryInfo
        previousBatteryInfo = current
        if old?.currentCapacity != current.currentCapacity { observers.send(.batteryLevelChanged(level: current.currentCapacity)) }
        if old?.maxCapacity != current.maxCapacity { observers.send(.maxCapacityChanged(capacity: current.maxCapacity)) }
        if old?.isPluggedIn != current.isPluggedIn { observers.send(.powerSourceChanged(isPluggedIn: current.isPluggedIn)) }
        if old?.isCharging != current.isCharging { observers.send(.isChargingChanged(isCharging: current.isCharging)) }
        if old?.isInLowPowerMode != current.isInLowPowerMode { observers.send(.lowPowerModeChanged(isEnabled: current.isInLowPowerMode)) }
        if old?.timeToFullCharge != current.timeToFullCharge { observers.send(.timeToFullChargeChanged(time: current.timeToFullCharge)) }
        onBatteryLevelChange?(current.currentCapacity); onMaxCapacityChange?(current.maxCapacity)
        onPowerSourceChange?(current.isPluggedIn); onChargingChange?(current.isCharging)
        onPowerModeChange?(current.isInLowPowerMode); onTimeToFullChargeChange?(current.timeToFullCharge)
    }
    private func readBatteryInfo() -> BatteryInfo? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
                  let charge = BatteryCharge(currentCapacity: current.doubleValue, maximumCapacity: maximum.doubleValue),
                  let power = description[kIOPSPowerSourceStateKey] as? String else { continue }
            return BatteryInfo(isPluggedIn: power == kIOPSACPowerValue,
                               isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                               currentCapacity: charge.percent, maxCapacity: 100,
                               isInLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                               timeToFullCharge: max(0, description[kIOPSTimeToFullChargeKey] as? Int ?? 0))
        }
        return nil
    }
    deinit {
        if let batterySource { CFRunLoopRemoveSource(CFRunLoopGetMain(), batterySource, .commonModes) }
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
    }
}

struct BatteryInfo: Sendable, Equatable {
    var isPluggedIn: Bool
    var isCharging: Bool
    var currentCapacity: Float
    var maxCapacity: Float
    var isInLowPowerMode: Bool
    var timeToFullCharge: Int
    static let unavailable = BatteryInfo(isPluggedIn: false, isCharging: false, currentCapacity: 0,
                                          maxCapacity: 0, isInLowPowerMode: false, timeToFullCharge: 0)
}
