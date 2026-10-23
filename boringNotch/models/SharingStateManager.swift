//
//  SharingStateManager.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-10.
//

import AppKit
import Combine
import Foundation
import BoringCore

extension Notification.Name {
	static let sharingDidFinish = Notification.Name("com.boringNotch.sharingDidFinish")
}

@MainActor
final class SharingStateManager: ObservableObject {
	static let shared = SharingStateManager()

	private var activeSessions: Int = 0 {
		didSet {
			let newValue = activeSessions > 0
			if newValue != preventNotchClose {
				preventNotchClose = newValue
				if !newValue {
					NotificationCenter.default.post(name: .sharingDidFinish, object: nil)
				}
			}
		}
	}

	@Published var preventNotchClose: Bool = false

	private var activeDelegates: [UUID: SharingLifecycleDelegate] = [:]

	private init() {}
	
	func requestCloseIfReady() {
		if !preventNotchClose {
			NotificationCenter.default.post(name: .sharingDidFinish, object: nil)
		}
	}

	func beginInteraction() {
		activeSessions += 1
	}

	func endInteraction() {
		if activeSessions > 0 { activeSessions -= 1 }
	}

	func makeDelegate(onEnd: (() -> Void)? = nil, onCompletion: ((Bool) -> Void)? = nil) -> SharingLifecycleDelegate {
		let id = UUID()
		let delegate = SharingLifecycleDelegate(id: id, onCompletion: { onCompletion?($0) }, onEnd: { [weak self] in
			onEnd?()
			self?.unregisterDelegate(id: id)
		}, onBegin: { [weak self] in
			self?.beginInteraction()
		}, onFinish: { [weak self] in
			self?.endInteraction()
		})
		activeDelegates[id] = delegate
		return delegate
	}

	private func unregisterDelegate(id: UUID) {
		activeDelegates.removeValue(forKey: id)
	}
}

@MainActor
final class SharingLifecycleDelegate: NSObject, NSSharingServiceDelegate, @preconcurrency NSSharingServicePickerDelegate {
    let id: UUID
    private let onEnd: () -> Void
    private let onBegin: () -> Void
    private let onFinish: () -> Void
    private let onCompletion: (Bool) -> Void
    private var lifetime = InteractionLifetime()

    init(id: UUID, onCompletion: @escaping (Bool) -> Void = { _ in }, onEnd: @escaping () -> Void,
         onBegin: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.id = id
        self.onCompletion = onCompletion
        self.onEnd = onEnd
        self.onBegin = onBegin
        self.onFinish = onFinish
    }
    func markPickerBegan() { if lifetime.beginPicker() { onBegin() } }
    func markServiceBegan() { if lifetime.beginService() { onBegin() } }
    func cancel() { finishIfNeeded(success: false) }
    private func finishIfNeeded(success: Bool) {
        guard let wasActive = lifetime.finish() else { return }
        if wasActive { onFinish() }
        onCompletion(success)
        onEnd()
    }
    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard let service else { finishIfNeeded(success: false); return }
        service.delegate = self
        markServiceBegan()
    }
    func sharingService(_ service: NSSharingService, willShareItems items: [Any]) { markServiceBegan() }
    func sharingService(_ service: NSSharingService, didShareItems items: [Any]) { finishIfNeeded(success: true) }
    func sharingService(_ service: NSSharingService, didFailToShareItems items: [Any], error: Error) { finishIfNeeded(success: false) }
}
