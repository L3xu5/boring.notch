import Foundation

public enum CalendarSelection: Sendable, Equatable {
    case all
    case none
    case identifiers(Set<String>)
    public func resolvedIDs(available: Set<String>) -> Set<String> {
        switch self {
        case .all: available
        case .none: []
        case .identifiers(let identifiers): identifiers.intersection(available)
        }
    }
}

public struct CalendarQuery: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let calendarIDs: Set<String>
    public init(start: Date, end: Date, calendarIDs: Set<String>) {
        self.start = start; self.end = end; self.calendarIDs = calendarIDs
    }
    public static func day(containing date: Date, calendar: Calendar = .current, calendarIDs: Set<String>) -> Self {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return .init(start: start, end: end, calendarIDs: calendarIDs)
    }
    public func contains(_ date: Date) -> Bool { date >= start && date < end }
    public static func date(from components: DateComponents, calendar fallback: Calendar = .current) -> Date? {
        var calendar = components.calendar ?? fallback
        if let timeZone = components.timeZone { calendar.timeZone = timeZone }
        return calendar.date(from: components)
    }
}

public struct CalendarRequest: Sendable, Equatable {
    public let id: UUID
    public let query: CalendarQuery
}

public struct CalendarRequestTracker: Sendable {
    private var currentID: UUID?
    public init() {}
    public mutating func begin(_ query: CalendarQuery) -> CalendarRequest {
        let id = UUID(); currentID = id
        return .init(id: id, query: query)
    }
    public func isCurrent(_ request: CalendarRequest) -> Bool { currentID == request.id }
    public mutating func invalidate() { currentID = nil }
}

/// EventKit's calendar item identifier identifies the series, not a displayed occurrence.
public struct CalendarOccurrenceID: Hashable, Sendable {
    public let sourceIdentifier: String
    public let occurrenceStart: Date?
    public init(sourceIdentifier: String, occurrenceStart: Date?) {
        self.sourceIdentifier = sourceIdentifier; self.occurrenceStart = occurrenceStart
    }
}
