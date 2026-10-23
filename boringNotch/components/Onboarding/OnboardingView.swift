import AppKit
import ApplicationServices
import AVFoundation
import BoringCore
import Defaults
import EventKit
import SwiftUI

struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Default(.mediaController) private var mediaController
    @Default(.showMirror) private var showMirror
    @Default(.showCalendar) private var showCalendar
    @Default(.hudReplacement) private var hudReplacement
    @State private var flow = OnboardingFlowState()
    @State private var permissionTask: Task<Void, Never>?
    @State private var permissionMessage: String?
    let onFinish: () -> Void
    let onOpenSettings: () -> Void
    private let calendarService = CalendarService()

    init(initialStage: SetupStage = .welcome, onFinish: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        var initialFlow = OnboardingFlowState()
        initialFlow.navigate(to: initialStage)
        _flow = State(initialValue: initialFlow)
        self.onFinish = onFinish
        self.onOpenSettings = onOpenSettings
    }

    private var stages: [SetupStage] {
        var result: [SetupStage] = [.welcome, .musicSource, .features]
        if mediaController == .yandexMusic || hudReplacement { result.append(.accessibility) }
        if showMirror { result.append(.camera) }
        if showCalendar { result.append(contentsOf: [.calendar, .reminders]) }
        return result + [.finished]
    }

    var body: some View {
        VStack(spacing: 0) {
            if flow.stage != .welcome && flow.stage != .finished {
                HStack {
                    Button("Back", systemImage: "chevron.left") { goBack() }
                        .buttonStyle(.borderless)
                    Spacer()
                    Text("Step \((stages.firstIndex(of: flow.stage) ?? 0) + 1) of \(stages.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24).padding(.top, 18)
            }
            content
        }
        .frame(minWidth: 440, idealWidth: 460, minHeight: 600, idealHeight: 640)
        .onDisappear { cancelRequest() }
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard permissionMessage != nil, flow.pendingRequest == nil else { return }
            requestPermission(prompt: false)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.stage {
        case .welcome:
            WelcomeView { navigate(to: .musicSource) }
        case .musicSource:
            MusicControllerSelectionView {
                BoringViewCoordinator.shared.firstLaunch = false
                navigate(to: .features)
            }
        case .features:
            VStack(alignment: .leading, spacing: 20) {
                Text("Make it yours").font(.largeTitle.bold())
                Text("Start with music, or add a couple of useful extras. You can change these choices later.")
                    .foregroundStyle(.secondary)
                Form {
                    Toggle(isOn: $showCalendar) { Label("Calendar & reminders", systemImage: "calendar") }
                    Toggle(isOn: $showMirror) { Label("Camera mirror", systemImage: "web.camera") }
                }
                .formStyle(.grouped)
                Text("Only the extras you enable will ask for access.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Continue") { advance() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(28)
        case .finished:
            OnboardingFinishView(
                onFinish: { finish(onFinish) }, onOpenSettings: { finish(onOpenSettings) }
            )
        case .accessibility, .camera, .calendar, .reminders:
            let presentation = permissionPresentation
            PermissionRequestView(
                icon: Image(systemName: presentation.icon), title: presentation.title,
                description: presentation.description, privacyNote: presentation.privacy,
                onAllow: {
                    if permissionMessage != nil { openPrivacySettings() } else { requestPermission(prompt: true) }
                },
                onSkip: { advance() }, isRequesting: flow.pendingRequest != nil,
                statusMessage: permissionMessage,
                allowTitle: permissionMessage == nil ? "Allow Access" : "Open Settings"
            )
        }
    }

    private var permissionPresentation: (icon: String, title: String, description: String, privacy: String) {
        switch flow.stage {
        case .accessibility:
            return ("hand.raised.fill", "Enable player control",
                    mediaController == .yandexMusic
                    ? "Accessibility lets the notch press Yandex Music's playback and like buttons. Your physical media keys still go to macOS first."
                    : "Accessibility lets the optional system HUD handle volume and brightness keys.",
                    "You can revoke this access at any time in System Settings.")
        case .camera:
            return ("camera.fill", "Set up the mirror", "Allow camera access to show a live preview when you open the mirror.", "The preview stays on your Mac. Nothing is recorded or stored.")
        case .calendar:
            return ("calendar", "Show your events", "Choose which calendars appear in the notch after granting access.", "Your events are used locally for the calendar view.")
        default:
            return ("checklist", "Show your reminders", "Include reminders alongside your events. You can choose lists in Settings.", "Your reminders are used locally for the calendar view.")
        }
    }

    private func nextStage() -> SetupStage {
        guard let index = stages.firstIndex(of: flow.stage), index + 1 < stages.count else { return .finished }
        return stages[index + 1]
    }

    private func navigate(to stage: SetupStage) {
        cancelRequest()
        permissionMessage = nil
        flow.navigate(to: stage)
    }

    private func advance() { navigate(to: nextStage()) }

    private func goBack() {
        guard let index = stages.firstIndex(of: flow.stage), index > 0 else { return }
        navigate(to: stages[index - 1])
    }

    private func cancelRequest() {
        permissionTask?.cancel()
        permissionTask = nil
        flow.navigate(to: flow.stage)
    }

    private func finish(_ action: () -> Void) {
        cancelRequest()
        BoringViewCoordinator.shared.firstLaunch = false
        action()
    }

    private func requestPermission(prompt: Bool) {
        let stage = flow.stage
        guard [.accessibility, .camera, .calendar, .reminders].contains(stage),
              let requestID = flow.beginRequest() else { return }
        let next = nextStage()
        permissionTask = Task { @MainActor in
            let granted = await permissionGranted(stage, prompt: prompt)
            guard !Task.isCancelled else { return }
            guard flow.finishRequest(requestID, from: stage, advancingTo: granted ? next : nil) else { return }
            permissionMessage = granted ? nil : "Access is not enabled yet. Enable it in System Settings, or continue without it for now."
            permissionTask = nil
        }
    }

    private func permissionGranted(_ stage: SetupStage, prompt: Bool) async -> Bool {
        switch stage {
        case .camera:
            if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { return true }
            if prompt { return await AVCaptureDevice.requestAccess(for: .video) }
            return false
        case .calendar:
            if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
            if prompt { return (try? await calendarService.requestAccess(to: .event)) ?? false }
            return false
        case .reminders:
            if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { return true }
            if prompt { return (try? await calendarService.requestAccess(to: .reminder)) ?? false }
            return false
        case .accessibility:
            var appGranted = true
            if mediaController == .yandexMusic {
                appGranted = prompt
                    ? AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                    : AXIsProcessTrusted()
            }
            var helperGranted = true
            if hudReplacement { helperGranted = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: prompt) }
            return appGranted && helperGranted
        default: return true
        }
    }

    private func openPrivacySettings() {
        let pane: String
        switch flow.stage {
        case .camera: pane = "Privacy_Camera"
        case .calendar: pane = "Privacy_Calendars"
        case .reminders: pane = "Privacy_Reminders"
        default: pane = "Privacy_Accessibility"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
