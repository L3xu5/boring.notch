import Foundation
import Testing
@testable import BoringCore

struct CalendarTests {
    @Test func noneNeverExpandsToAllCalendars() {
        let available: Set<String> = ["work", "private"]
        #expect(CalendarSelection.none.resolvedIDs(available: available).isEmpty)
        #expect(CalendarSelection.identifiers([]).resolvedIDs(available: available).isEmpty)
        #expect(CalendarSelection.all.resolvedIDs(available: available) == available)
        #expect(CalendarSelection.identifiers(["work", "removed"]).resolvedIDs(available: available) == ["work"])
    }
    @Test func dayBoundsExcludeTomorrowAndRespectDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let query = CalendarQuery.day(containing: date, calendar: calendar, calendarIDs: [])
        #expect(query.end.timeIntervalSince(query.start) == 23 * 60 * 60)
        #expect(query.contains(query.start))
        #expect(!query.contains(query.end))
        #expect(query.contains(query.end.addingTimeInterval(-1)))
    }
    @Test func sameDayReloadAndChangedSelectionInvalidatePreviousResponses() {
        var tracker = CalendarRequestTracker()
        let query = CalendarQuery.day(containing: Date(), calendarIDs: ["work"])
        let first = tracker.begin(query)
        let reload = tracker.begin(query)
        #expect(!tracker.isCurrent(first))
        #expect(tracker.isCurrent(reload))
        let privateCalendar = tracker.begin(.day(containing: Date(), calendarIDs: ["private"]))
        #expect(!tracker.isCurrent(reload))
        #expect(tracker.isCurrent(privateCalendar))
        tracker.invalidate()
        #expect(!tracker.isCurrent(privateCalendar))
    }
}

struct CalendarCallbackTests {
    @Test func cancellationBeforeRegistrationWinsOverLateCallback() async {
        let callback = CallbackResult<[String]>()
        callback.cancel(returning: [])
        let value = await withCheckedContinuation { callback.install($0) }
        callback.resume(returning: ["late"])
        #expect(value.isEmpty)
    }
    @Test func completedCallbackSurvivesSubsequentCancellation() async {
        let callback = CallbackResult<[String]>()
        callback.resume(returning: ["ready"])
        callback.cancel(returning: [])
        let value = await withCheckedContinuation { callback.install($0) }
        #expect(value == ["ready"])
    }
}

struct CalendarOccurrenceTests {
    @Test func recurringOccurrencesNeverShareTheSameListIdentity() {
        let first = CalendarOccurrenceID(sourceIdentifier: "series", occurrenceStart: Date(timeIntervalSince1970: 0))
        let second = CalendarOccurrenceID(sourceIdentifier: "series", occurrenceStart: Date(timeIntervalSince1970: 3600))
        #expect(first != second)
        #expect(first.sourceIdentifier == second.sourceIdentifier)
    }
}
