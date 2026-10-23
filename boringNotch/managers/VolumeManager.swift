//
//  VolumeManager.swift
//  boringNotch
//
//  Created by JeanLouis on 22/08/2025.
//

import AppKit
import Combine
import CoreAudio
import Foundation

@MainActor
final class VolumeManager: NSObject, ObservableObject {
    static let shared = VolumeManager()

    @Published private(set) var rawVolume: Float = 0
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var isAvailable = false
    @Published private(set) var lastChangeAt: Date = .distantPast

    let visibleDuration: TimeInterval = 1.2

    private var didInitialFetch = false
    private var observedDevice: AudioObjectID = kAudioObjectUnknown
    private var defaultDeviceObservation: AudioListenerRegistration?
    private var deviceObservations: [AudioListenerRegistration] = []
    private let step: Float32 = 1.0 / 16.0
    // Fallback software if hardware mute is not supported
    private var previousVolumeBeforeMute: Float32 = 0.2
    private var softwareMuted: Bool = false

    private override init() {
        super.init()
        setupAudioListener()
        fetchCurrentVolume()
    }

    var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

    // MARK: - Public Control API
    @MainActor func increase(stepDivisor: Float = 1.0) {
        guard stepDivisor.isFinite else { return }
        let divisor = max(stepDivisor, 0.25)
        let delta = step / Float32(divisor)
        let current = readVolumeInternal() ?? rawVolume
        let target = max(0, min(1, current + delta))
        setAbsolute(target)
        BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(target))
    }

    @MainActor func decrease(stepDivisor: Float = 1.0) {
        guard stepDivisor.isFinite else { return }
        let divisor = max(stepDivisor, 0.25)
        let delta = step / Float32(divisor)
        let current = readVolumeInternal() ?? rawVolume
        let target = max(0, min(1, current - delta))
        setAbsolute(target)
        BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(target))
    }

    func toggleMuteAction() {
        toggleMuteInternal()
        BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(isMuted ? 0 : rawVolume))
    }

    func refresh() { fetchCurrentVolume() }

    func adjustRelative(delta: Float32) {
        guard delta.isFinite else { return }
        if isMutedInternal() { toggleMuteInternal() }
        guard let current = readVolumeInternal() else {
            fetchCurrentVolume()
            return
        }
        let target = max(0, min(1, current + delta))
        guard writeVolumeInternal(target) else { fetchCurrentVolume(); return }
        publish(volume: target, muted: isMutedInternal(), touchDate: true)
    }

    @MainActor func setAbsolute(_ value: Float32) {
        guard value.isFinite else { return }
        let clamped = max(0, min(1, value))
        let currentlyMuted = isMutedInternal()
        if currentlyMuted && clamped > 0 {
            toggleMuteInternal()
        }

        guard writeVolumeInternal(clamped) else { fetchCurrentVolume(); return }

        if clamped == 0 && !currentlyMuted {
            toggleMuteInternal()
        }

        publish(volume: clamped, muted: isMutedInternal(), touchDate: true)
    }

    // MARK: - CoreAudio Helpers
    private func systemOutputDeviceID() -> AudioObjectID {
        var defaultDeviceID = kAudioObjectUnknown
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &defaultDeviceID
        )
        if status != noErr { return kAudioObjectUnknown }
        return defaultDeviceID
    }

    private func fetchCurrentVolume() {
        let value = readVolumeInternal()
        isAvailable = value != nil
        guard let value else { return }
        let muted = isMutedInternal()
        if didInitialFetch && (rawVolume != value || isMuted != muted) { lastChangeAt = Date() }
        rawVolume = value
        isMuted = muted
        didInitialFetch = true
    }

    private func setupAudioListener() {
        let address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        defaultDeviceObservation = AudioListenerRegistration(object: AudioObjectID(kAudioObjectSystemObject), address: address) { [weak self] in
            Task { @MainActor in self?.rebindOutputDevice() }
        }
        rebindOutputDevice()
    }

    private func rebindOutputDevice() {
        let device = systemOutputDeviceID()
        guard device != observedDevice else { fetchCurrentVolume(); return }
        deviceObservations.forEach { $0.invalidate() }
        deviceObservations.removeAll()
        observedDevice = device
        softwareMuted = false
        didInitialFetch = false
        guard device != kAudioObjectUnknown else { isAvailable = false; return }
        let selectors = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute]
        for selector in selectors {
            let elements: [UInt32] = selector == kAudioDevicePropertyMute ? [kAudioObjectPropertyElementMain]
                : [kAudioObjectPropertyElementMain, 1, 2, 3, 4]
            for element in elements {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
                guard AudioObjectHasProperty(device, &address) else { continue }
                if let observation = AudioListenerRegistration(object: device, address: address, onChange: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.observedDevice == device else { return }
                        self.fetchCurrentVolume()
                    }
                }) { deviceObservations.append(observation) }
            }
        }
        fetchCurrentVolume()
    }

    private func readVolumeInternal() -> Float32? {
        let deviceID = systemOutputDeviceID()
        if deviceID == kAudioObjectUnknown { return nil }
        if let master = readValidatedScalar(deviceID: deviceID, element: kAudioObjectPropertyElementMain) { return master }
        let channels = [UInt32](1...4).compactMap { readValidatedScalar(deviceID: deviceID, element: $0) }
        guard !channels.isEmpty else { return nil }
        return channels.reduce(0, +) / Float32(channels.count)
    }

    @discardableResult
    private func writeVolumeInternal(_ value: Float32) -> Bool {
        guard value.isFinite else { return false }
        let deviceID = systemOutputDeviceID()
        if deviceID == kAudioObjectUnknown { return false }
        let newVal = max(0, min(1, value))

        var written = false
        if writeValidatedScalar(
            deviceID: deviceID, element: kAudioObjectPropertyElementMain, value: newVal)
        {
            written = true
        } else {
            var any = false
            for el in [UInt32](1...4) {
                if writeValidatedScalar(deviceID: deviceID, element: el, value: newVal) {
                    any = true
                }
            }
            written = any
        }
        return written
    }

    private func isMutedInternal() -> Bool {
        let deviceID = systemOutputDeviceID()
        if deviceID == kAudioObjectUnknown { return softwareMuted }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &muteAddr) else { return softwareMuted }
        var sizeNeeded: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &muteAddr, 0, nil, &sizeNeeded) == noErr,
            sizeNeeded == UInt32(MemoryLayout<UInt32>.size)
        else { return softwareMuted }
        var muted: UInt32 = 0
        var size = sizeNeeded
        if AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &size, &muted) == noErr {
            return muted != 0
        }
        return softwareMuted
    }

    private func toggleMuteInternal() {
        let deviceID = systemOutputDeviceID()
        if deviceID == kAudioObjectUnknown {
            performSoftwareMuteToggle(currentVolume: rawVolume)
            return
        }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if !AudioObjectHasProperty(deviceID, &muteAddr) {
            let currentVol = readVolumeInternal() ?? rawVolume
            performSoftwareMuteToggle(currentVolume: currentVol)
            return
        }
        var sizeNeeded: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &muteAddr, 0, nil, &sizeNeeded) == noErr,
            sizeNeeded == UInt32(MemoryLayout<UInt32>.size)
        else {
            let currentVol = readVolumeInternal() ?? rawVolume
            performSoftwareMuteToggle(currentVolume: currentVol)
            return
        }
        var muted: UInt32 = 0
        var size = sizeNeeded
        if AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &size, &muted) == noErr {
            var newVal: UInt32 = muted == 0 ? 1 : 0
            guard AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, size, &newVal) == noErr else {
                performSoftwareMuteToggle(currentVolume: readVolumeInternal() ?? rawVolume)
                return
            }
            let vol = readVolumeInternal() ?? rawVolume
            publish(volume: vol, muted: newVal != 0, touchDate: true)
        } else {
            let currentVol = readVolumeInternal() ?? rawVolume
            performSoftwareMuteToggle(currentVolume: currentVol)
        }
    }

    private func performSoftwareMuteToggle(currentVolume: Float32) {
        if softwareMuted {
            let restore = max(0, min(1, previousVolumeBeforeMute))
            guard writeVolumeInternal(restore) else { return }
            softwareMuted = false
            publish(volume: restore, muted: false, touchDate: true)
        } else {
            if currentVolume > 0.001 { previousVolumeBeforeMute = currentVolume }
            guard writeVolumeInternal(0) else { return }
            softwareMuted = true
            publish(volume: 0, muted: true, touchDate: true)
        }
    }

    private func readValidatedScalar(deviceID: AudioObjectID, element: UInt32) -> Float32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return nil }
        var sizeNeeded: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &sizeNeeded) == noErr,
            sizeNeeded == UInt32(MemoryLayout<Float32>.size)
        else { return nil }
        var vol = Float32(0)
        var size = sizeNeeded
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &vol)
        return status == noErr && vol.isFinite ? max(0, min(1, vol)) : nil
    }

    private func writeValidatedScalar(deviceID: AudioObjectID, element: UInt32, value: Float32)
        -> Bool
    {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return false }
        var sizeNeeded: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &sizeNeeded) == noErr,
            sizeNeeded == UInt32(MemoryLayout<Float32>.size)
        else { return false }
        var val = value
        return AudioObjectSetPropertyData(deviceID, &addr, 0, nil, sizeNeeded, &val) == noErr
    }

    private func publish(volume: Float32, muted: Bool, touchDate: Bool) {
        if touchDate { lastChangeAt = Date() }
        rawVolume = volume
        isMuted = muted
    }
}

extension Array where Element == Float32 {
    fileprivate var average: Float32? { isEmpty ? nil : reduce(0, +) / Float32(count) }
}



/// Owns exactly the block registered with CoreAudio, including removal when its parent is
/// replaced or destroyed. Callbacks retain the UI manager weakly and ignore obsolete devices.
private final class AudioListenerRegistration: @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let lock = NSLock()
    private var active = true
    init?(object: AudioObjectID, address: AudioObjectPropertyAddress, onChange: @escaping @Sendable () -> Void) {
        self.object = object
        self.address = address
        block = { _, _ in onChange() }
        var address = address
        guard AudioObjectAddPropertyListenerBlock(object, &address, nil, block) == noErr else { active = false; return nil }
    }
    func invalidate() {
        lock.lock()
        guard active else { lock.unlock(); return }
        active = false
        var address = self.address
        lock.unlock()
        AudioObjectRemovePropertyListenerBlock(object, &address, nil, block)
    }
    deinit { invalidate() }
}
