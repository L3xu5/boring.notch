//
//  CalendarManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import Combine
import EventKit
import SwiftUI
import BoringCore

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    // Settings owns permission/list state; each visible calendar owns a separate day query.
    static let shared = CalendarManager(loadEvents: false)

    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    private var selectedCalendars: [CalendarModel] = []
    private let calendarService: any CalendarServiceProviding
    private let loadsEvents: Bool
    private var selectionObservation: AnyCancellable?
    private var eventRequestTracker = CalendarRequestTracker()
    private var eventTask: Task<[EventModel], Never>?
    private var reloadTask: Task<Void, Never>?
    private var listRequestID = UUID()

    private var eventStoreChangedObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?

    init(calendarService: any CalendarServiceProviding = CalendarService.shared, loadEvents: Bool = true) {
        self.calendarService = calendarService
        self.loadsEvents = loadEvents
        self.currentWeekStartDate = CalendarManager.startOfDay(Date())
        guard !ShelfStorageEnvironment.isIsolatedPreview else { return }
        setupEventStoreChangedObserver()
        selectionObservation = Defaults.publisher(.calendarSelectionState).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateSelectedCalendars()
                await self.updateEvents()
            }
        }
        Task {
            await reloadCalendarAndReminderLists()
        }
    }

    deinit {
        eventTask?.cancel()
        reloadTask?.cancel()
        if let observer = eventStoreChangedObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = appActivationObserver { NotificationCenter.default.removeObserver(observer) }
    }

    private func setupEventStoreChangedObserver() {
        appActivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reloadCalendarAndReminderLists() }
        }
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reloadTask?.cancel()
                self.reloadTask = Task {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    await self.reloadCalendarAndReminderLists()
                }
            }
        }
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        guard !ShelfStorageEnvironment.isIsolatedPreview else { return }
        let requestID = UUID()
        listRequestID = requestID
        calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        let all = await calendarService.calendars()
        guard !Task.isCancelled, listRequestID == requestID else { return }
        self.eventCalendars = all.filter { !$0.isReminder }
        self.reminderLists = all.filter { $0.isReminder }
        self.allCalendars = all // for legacy compatibility, can be removed if not needed
        updateSelectedCalendars()
        await updateEvents()
    }

    func checkCalendarAuthorization() async {
        guard !ShelfStorageEnvironment.isIsolatedPreview else { return }
        let status = EKEventStore.authorizationStatus(for: .event)
        calendarAuthorizationStatus = status

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .event) else {
                self.calendarAuthorizationStatus = .notDetermined
                return
            }
            self.calendarAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
            }
        case .restricted, .denied:
            await reloadCalendarAndReminderLists()
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
    
    func checkReminderAuthorization() async {
        guard !ShelfStorageEnvironment.isIsolatedPreview else { return }
        let status = EKEventStore.authorizationStatus(for: .reminder)
        reminderAuthorizationStatus = status

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .reminder) else {
                self.reminderAuthorizationStatus = .notDetermined
                return
            }
            self.reminderAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
            }
        case .restricted, .denied:
            await reloadCalendarAndReminderLists()
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
        

    func updateSelectedCalendars() {
        // Populate selectedCalendarIDs based on Defaults calendar selection state
        let policy: CalendarSelection
        switch Defaults[.calendarSelectionState] {
        case .all: policy = .all
        case .selected(let identifiers): policy = identifiers.isEmpty ? .none : .identifiers(identifiers)
        }
        selectedCalendarIDs = policy.resolvedIDs(available: Set(allCalendars.map(\.id)))

        // Update the local calendar objects that correspond to the selected ids
        selectedCalendars = allCalendars.filter { selectedCalendarIDs.contains($0.id) }
        events.removeAll { !selectedCalendarIDs.contains($0.calendar.id) }
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        return selectedCalendarIDs.contains(calendar.id)
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }

        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            selectionState =
                identifiers.count == allCalendars.count && !identifiers.isEmpty ? .all : .selected(identifiers)
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        await updateEvents()
    }

    static func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    func updateCurrentDate(_ date: Date) async {
        let day = Calendar.current.startOfDay(for: date)
        if day != currentWeekStartDate { events = [] }
        currentWeekStartDate = day
        await updateEvents()
    }

    private func updateEvents() async {
        guard loadsEvents, !ShelfStorageEnvironment.isIsolatedPreview else { return }
        eventTask?.cancel()
        let query = CalendarQuery.day(containing: currentWeekStartDate, calendarIDs: selectedCalendarIDs)
        let request = eventRequestTracker.begin(query)
        guard !query.calendarIDs.isEmpty else { events = []; return }
        let service = calendarService
        let task = Task {
            await service.events(from: query.start, to: query.end, calendars: Array(query.calendarIDs))
        }
        eventTask = task
        let result = await task.value
        guard !Task.isCancelled, eventRequestTracker.isCurrent(request) else { return }
        events = result
    }

    func setReminderCompleted(reminderID: String, completed: Bool) async {
        guard !ShelfStorageEnvironment.isIsolatedPreview else { return }
        await calendarService.setReminderCompleted(reminderID: reminderID, completed: completed)
        // Refresh events after updating
        await updateEvents()
    }
}
