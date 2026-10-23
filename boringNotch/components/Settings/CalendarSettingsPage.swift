import AppKit
import Defaults
import EventKit
import SwiftUI

struct CalendarSettings: View {
    @State private var permissionRequest: Task<Void, Never>?
    @State private var requestingEntity: EKEntityType?
    @State private var permissionRequestID = UUID()
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.showCalendar) var showCalendar: Bool
    @Default(.hideCompletedReminders) var hideCompletedReminders
    @Default(.hideAllDayEvents) var hideAllDayEvents
    @Default(.autoScrollToNextEvent) var autoScrollToNextEvent

    var body: some View {
        Form {
            Defaults.Toggle(key: .showCalendar) {
                Text("Show calendar")
            }
            Defaults.Toggle(key: .hideCompletedReminders) {
                Text("Hide completed reminders")
            }
            Defaults.Toggle(key: .hideAllDayEvents) {
                Text("Hide all-day events")
            }
            Defaults.Toggle(key: .autoScrollToNextEvent) {
                Text("Auto-scroll to next event")
            }
            Defaults.Toggle(key: .showFullEventTitles) {
                Text("Always show full event titles")
            }
            Section(header: Text("Calendars")) {
                if calendarManager.calendarAuthorizationStatus != .fullAccess {
                    Text(calendarManager.calendarAuthorizationStatus == .notDetermined
                         ? "Calendar access is optional. Allow access to choose which calendars appear."
                         : "Calendar access is not enabled. You can change it in System Settings.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    if calendarManager.calendarAuthorizationStatus == .notDetermined {
                        Button("Allow Calendar Access") { requestPermission(for: .event) }
                            .disabled(requestingEntity != nil)
                    } else {
                    Button("Open Calendar Settings") {
                        if let settingsURL = URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                        ) {
                            NSWorkspace.shared.open(settingsURL)
                        }
                    }
                    }
                } else {
                    List {
                        ForEach(calendarManager.eventCalendars, id: \.id) { calendar in
                            Toggle(
                                isOn: Binding(
                                    get: { calendarManager.getCalendarSelected(calendar) },
                                    set: { isSelected in
                                        Task {
                                            await calendarManager.setCalendarSelected(
                                                calendar, isSelected: isSelected)
                                        }
                                    }
                                )
                            ) {
                                Text(calendar.title)
                            }
                            .accentColor(lighterColor(from: calendar.color))
                            .disabled(!showCalendar)
                        }
                    }
                }
            }
            Section(header: Text("Reminders")) {
                if calendarManager.reminderAuthorizationStatus != .fullAccess {
                    Text(calendarManager.reminderAuthorizationStatus == .notDetermined
                         ? "Reminder access is optional. Allow access to choose which lists appear."
                         : "Reminder access is not enabled. You can change it in System Settings.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    if calendarManager.reminderAuthorizationStatus == .notDetermined {
                        Button("Allow Reminder Access") { requestPermission(for: .reminder) }
                            .disabled(requestingEntity != nil)
                    } else {
                    Button("Open Reminder Settings") {
                        if let settingsURL = URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
                        ) {
                            NSWorkspace.shared.open(settingsURL)
                        }
                    }
                    }
                } else {
                    List {
                        ForEach(calendarManager.reminderLists, id: \.id) { calendar in
                            Toggle(
                                isOn: Binding(
                                    get: { calendarManager.getCalendarSelected(calendar) },
                                    set: { isSelected in
                                        Task {
                                            await calendarManager.setCalendarSelected(
                                                calendar, isSelected: isSelected)
                                        }
                                    }
                                )
                            ) {
                                Text(calendar.title)
                            }
                            .accentColor(lighterColor(from: calendar.color))
                            .disabled(!showCalendar)
                        }
                    }
                }
            }
        }
        .accentColor(.effectiveAccent)
        .task { await calendarManager.reloadCalendarAndReminderLists() }
        .onDisappear {
            permissionRequestID = UUID()
            permissionRequest?.cancel()
            permissionRequest = nil
            requestingEntity = nil
        }
    }

    private func requestPermission(for entity: EKEntityType) {
        guard requestingEntity == nil else { return }
        let id = UUID()
        permissionRequestID = id
        requestingEntity = entity
        permissionRequest = Task { @MainActor in
            guard !Task.isCancelled, permissionRequestID == id else { return }
            if entity == .event { await calendarManager.checkCalendarAuthorization() }
            else { await calendarManager.checkReminderAuthorization() }
            guard !Task.isCancelled, permissionRequestID == id else { return }
            requestingEntity = nil
            permissionRequest = nil
        }
    }
}
