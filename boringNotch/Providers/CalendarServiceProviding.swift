//
//  CalendarServiceProvider.swift
//  Calendr
//
//  Created by Paker on 31/12/20.
//  Original source: Original source: https://github.com/pakerwreah/Calendr
//  Modified by Alexander on 08/06/25
//

import Foundation
import BoringCore
@preconcurrency import EventKit

protocol CalendarServiceProviding: Sendable {
    func requestAccess(to type: EKEntityType) async throws -> Bool
    func calendars() async -> [CalendarModel]
    func events(from start: Date, to end: Date, calendars: [String]) async -> [EventModel]
    func setReminderCompleted(reminderID: String, completed: Bool) async
}

actor CalendarService: CalendarServiceProviding {
    static let shared = CalendarService()
    private let store: EKEventStore?
    init(storeFactory: @Sendable () -> EKEventStore = { EKEventStore() }) {
        // The exact Debug preview must not even construct EventKit's live store.
        store = ShelfStorageEnvironment.isIsolatedPreview ? nil : storeFactory()
    }
    
    func requestAccess(to type: EKEntityType) async throws -> Bool {
        guard let store, !ShelfStorageEnvironment.isIsolatedPreview else { return false }
        if #available(macOS 14.0, *) {
            switch type {
            case .event:
                return try await store.requestFullAccessToEvents()
            case .reminder:
                return try await store.requestFullAccessToReminders()
            @unknown default:
                return false
            }
        } else {
            return try await store.requestAccess(to: type)
        }
    }
    
    private func hasAccess(to entityType: EKEntityType) -> Bool {
        guard !ShelfStorageEnvironment.isIsolatedPreview else { return false }
        let status = EKEventStore.authorizationStatus(for: entityType)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }
    
    func calendars() async -> [CalendarModel] {
        guard let store, !ShelfStorageEnvironment.isIsolatedPreview else { return [] }
        var calendars: [EKCalendar] = []
        
        for type in [EKEntityType.event, .reminder] where hasAccess(to: type) {
            calendars.append(contentsOf: store.calendars(for: type))
        }
        
        return calendars.map { CalendarModel(from: $0) }
    }
    
    func events(from start: Date, to end: Date, calendars ids: [String]) async -> [EventModel] {
        guard let store, !ShelfStorageEnvironment.isIsolatedPreview, !Task.isCancelled, !ids.isEmpty else { return [] }
        let eventCalendars = hasAccess(to: .event) ? store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) } : []
        let reminderCalendars = hasAccess(to: .reminder) ? store.calendars(for: .reminder).filter { ids.contains($0.calendarIdentifier) } : []

        var events: [EventModel] = []
        
        // Fetch regular events
        if hasAccess(to: .event), !eventCalendars.isEmpty {
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: eventCalendars)
            let ekEvents = store.events(matching: predicate)
            events.append(contentsOf: ekEvents.compactMap { EventModel(from: $0) })
        }
        
        // Fetch reminders
        if hasAccess(to: .reminder), !reminderCalendars.isEmpty {
            events.append(contentsOf: await fetchReminders(from: start, to: end, calendars: reminderCalendars))
        }
        
        guard !Task.isCancelled else { return [] }
        return events.sorted { $0.start < $1.start }
    }
    
    private func fetchReminders(from start: Date, to end: Date, calendars: [EKCalendar]) async -> [EventModel] {
        let result = CallbackResult<[EventModel]>()
        guard let store else { return [] }
        let query = CalendarQuery(start: start, end: end, calendarIDs: [])
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                result.install(continuation)
                guard !Task.isCancelled else { result.cancel(returning: []); return }
                let predicate = store.predicateForReminders(in: calendars)
                let token = store.fetchReminders(matching: predicate) { reminders in
                    let events = (reminders ?? []).compactMap { reminder -> EventModel? in
                        guard let components = reminder.dueDateComponents,
                              let date = CalendarQuery.date(from: components), query.contains(date) else { return nil }
                        return EventModel(from: reminder)
                    }
                    result.resume(returning: events)
                }
                let cancellation = EventKitFetchCancellation(store: store, token: token)
                result.onCancel { cancellation.cancel() }
            }
        } onCancel: { result.cancel(returning: []) }
    }

    func setReminderCompleted(reminderID: String, completed: Bool) async {
        guard let store, !ShelfStorageEnvironment.isIsolatedPreview else { return }
        guard let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder else { return }
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
        } catch {
            print("Failed to update reminder completion: \(error)")
        }
    }
}

// MARK: - Model Extensions

extension CalendarModel {
    init(from calendar: EKCalendar) {
        self.init(
            id: calendar.calendarIdentifier,
            account: calendar.accountTitle,
            title: calendar.title,
            color: calendar.color,
            isSubscribed: calendar.isSubscribed || calendar.isDelegate,
            isReminder: calendar.allowedEntityTypes.contains(.reminder)
        )
    }
}

extension EventModel {
    init?(from event: EKEvent) {
        guard let calendar = event.calendar else { return nil }
        
        self.init(
            id: event.calendarItemIdentifier,
            start: event.startDate,
            end: event.endDate,
            title: event.title ?? "",
            location: event.location,
            notes: event.notes,
            url: event.url,
            isAllDay: event.shouldBeAllDay,
            type: .init(from: event),
            calendar: .init(from: calendar),
            participants: .init(from: event),
            timeZone: calendar.isSubscribed || calendar.isDelegate ? nil : event.timeZone,
            hasRecurrenceRules: event.hasRecurrenceRules || event.isDetached,
            priority: nil
        )
    }
    
    init?(from reminder: EKReminder) {
        guard let calendar = reminder.calendar,
              let dueDateComponents = reminder.dueDateComponents,
              let date = CalendarQuery.date(from: dueDateComponents)
        else { return nil }
        
        self.init(
            id: reminder.calendarItemIdentifier,
            start: date,
            end: Calendar.current.endOfDay(for: date),
            title: reminder.title ?? "",
            location: reminder.location,
            notes: reminder.notes,
            url: reminder.url,
            isAllDay: dueDateComponents.hour == nil,
            type: .reminder(completed: reminder.isCompleted),
            calendar: .init(from: calendar),
            participants: [],
            timeZone: calendar.isSubscribed || calendar.isDelegate ? nil : reminder.timeZone,
            hasRecurrenceRules: reminder.hasRecurrenceRules,
            priority: .init(from: reminder.priority)
        )
    }
}

extension EventType {
    init(from event: EKEvent) {
        self = event.birthdayContactIdentifier != nil ? .birthday : .event(.init(from: event.currentUser?.participantStatus))
    }
}

extension AttendanceStatus {
    init(from status: EKParticipantStatus?) {
        switch status {
        case .accepted:
            self = .accepted
        case .tentative:
            self = .maybe
        case .declined:
            self = .declined
        case .pending:
            self = .pending
        default:
            self = .unknown
        }
    }
}

extension Array where Element == Participant {
    init(from event: EKEvent) {
        var participants = event.attendees ?? []
        if let organizer = event.organizer, !participants.contains(where: { $0.url == organizer.url }) {
            participants.append(organizer)
        }
        self.init(
            participants.map { .init(from: $0, isOrganizer: $0.url == event.organizer?.url) }
        )
    }
}

extension Participant {
    init(from participant: EKParticipant, isOrganizer: Bool) {
        self.init(
            name: participant.name ?? participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
            status: .init(from: participant.participantStatus),
            isOrganizer: isOrganizer,
            isCurrentUser: participant.isCurrentUser
        )
    }
}

extension Priority {
    init?(from p: Int) {
        switch p {
        case 1...4:
            self = .high
        case 5:
            self = .medium
        case 6...9:
            self = .low
        default:
            return nil
        }
    }
}

// MARK: - Helper Extensions

private extension EKCalendar {
    var accountTitle: String {
        switch source.sourceType {
        case .local, .subscribed, .birthdays:
            return "Other"
        default:
            return source.title
        }
    }
    
    var isDelegate: Bool {
        if #available(macOS 13.0, *) {
            return source.isDelegate
        } else {
            return false
        }
    }
}

private extension EKEvent {
    var currentUser: EKParticipant? {
        attendees?.first(where: \.isCurrentUser)
    }
    
    var shouldBeAllDay: Bool {
        guard !isAllDay else { return true }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: startDate)
        let endOfDay = calendar.dateInterval(of: .day, for: endDate)?.end
        return startDate == startOfDay && endDate == endOfDay
    }
}

private extension Calendar {
    func endOfDay(for date: Date) -> Date {
        dateInterval(of: .day, for: date)?.end ?? date
    }
}

/// EventKit's opaque fetch token is valid only for cancellation on its originating store.
/// No model or mutable EventKit record is shared through this wrapper.
private final class EventKitFetchCancellation: @unchecked Sendable {
    let store: EKEventStore
    let token: Any
    init(store: EKEventStore, token: Any) { self.store = store; self.token = token }
    func cancel() { store.cancelFetchRequest(token) }
}
