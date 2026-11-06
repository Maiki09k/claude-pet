import EventKit
import Observation
import SwiftUI

struct AgendaEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: Color
    var location: String?
    /// Google Meet, Zoom, Teams or Webex link found in the event.
    var meetingURL: URL?
}

/// A calendar as the settings list it: name, account and colour.
struct CalendarChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let account: String
    let color: Color
}

/// Today's and tomorrow's appointments from the macOS calendar (including synced Google calendars).
@MainActor @Observable
final class Agenda {
    enum Access { case unknown, granted, denied }

    var access = Access.unknown
    var events: [AgendaEvent] = []
    /// No calendar besides the local ones: the Google account is probably not added to macOS.
    var onlyLocalCalendars = false
    /// Every calendar on this Mac, grouped by account, for the settings.
    var calendars: [CalendarChoice] = []

    @ObservationIgnored private let store = EKEventStore()

    func setCalendar(_ id: String, shown: Bool) {
        var hidden = Set(UserDefaults.standard.stringArray(forKey: Setting.hiddenCalendars) ?? [])
        if shown { hidden.remove(id) } else { hidden.insert(id) }
        UserDefaults.standard.set(hidden.sorted(), forKey: Setting.hiddenCalendars)
        refresh()
    }

    /// For the "calendar-check" preview: every calendar with its account and how many appointments
    /// it holds in the next two weeks. Counts only, no titles of appointments.
    func diagnose() -> String {
        guard access == .granted else { return "kein Kalenderzugriff" }
        let start = Date.now, end = start.addingTimeInterval(14 * 86400)
        let hidden = Set(UserDefaults.standard.stringArray(forKey: Setting.hiddenCalendars) ?? [])
        return store.calendars(for: .event)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
            .map { calendar in
                let count = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: [calendar])).count
                return "\(calendar.source.title) [\(calendar.source.sourceType.rawValue)] › \(calendar.title): \(count) Termine"
                    + (hidden.contains(calendar.calendarIdentifier) ? " (ausgeblendet)" : "")
            }
            .joined(separator: "\n")
            + "\nIn der Notch als Nächstes: " + (events.first { !$0.allDay }.map { AgendaEvent.clock($0.start) } ?? "nichts")
    }

    func start() async {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .granted
        case .notDetermined:
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            access = granted ? .granted : .denied
        default:
            access = .denied
        }
        guard access == .granted else { return }
        refresh()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Countdowns and the day change need a regular tick even without calendar edits.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let calendar = Calendar.current
        let now = Date.now
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 2, to: start) else { return }
        let all = store.calendars(for: .event)
        onlyLocalCalendars = all.allSatisfy { $0.source.sourceType == .local || $0.source.sourceType == .birthdays }
        let choices = all
            .map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title, color: Color(cgColor: $0.cgColor)) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        if choices != calendars { calendars = choices }
        // Calendars switched off in the settings.
        let hidden = Set(UserDefaults.standard.stringArray(forKey: Setting.hiddenCalendars) ?? [])
        let shown = all.filter { !hidden.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else { events = []; return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: shown)
        let found = store.events(matching: predicate).filter { $0.endDate > now && $0.status != .canceled }
        let timed = found.filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }

        // Several holiday calendars announce the same day ("Ende der Sommerzeit" twice, once in
        // English). Own all-day entries all stay; holidays shrink to one per day, German first.
        func isHoliday(_ event: EKEvent) -> Bool {
            let title = event.calendar.title
            return event.calendar.type == .subscription || event.calendar.type == .birthday
                || title.localizedCaseInsensitiveContains("feiertag") || title.localizedCaseInsensitiveContains("holiday")
        }
        func germanFirst(_ a: EKEvent, _ b: EKEvent) -> Bool {
            let aGerman = a.calendar.title.localizedCaseInsensitiveContains("feiertag")
            let bGerman = b.calendar.title.localizedCaseInsensitiveContains("feiertag")
            return aGerman != bGerman ? aGerman : (a.title ?? "") > (b.title ?? "")
        }
        var allDay: [EKEvent] = []
        for event in found.filter(\.isAllDay).sorted(by: { $0.startDate != $1.startDate ? $0.startDate < $1.startDate : germanFirst($0, $1) }) {
            let sameDay = allDay.filter { calendar.isDate($0.startDate, inSameDayAs: event.startDate) }
            if isHoliday(event) ? sameDay.contains(where: isHoliday) : sameDay.contains(where: { $0.title == event.title }) { continue }
            allDay.append(event)
        }

        events = (timed + allDay).map { event in
            AgendaEvent(id: event.eventIdentifier ?? UUID().uuidString,
                        title: event.title ?? "Termin",
                        start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                        color: Color(cgColor: event.calendar.cgColor),
                        location: event.location.flatMap { $0.isEmpty || Self.meetingLink(in: $0) != nil ? nil : $0 },
                        meetingURL: Self.meetingLink(in: [event.url?.absoluteString, event.location, event.notes]
                            .compactMap { $0 }.joined(separator: " ")))
        }
    }

    private static let meetingHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com"]

    static func meetingLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap(\.url).first { url in
            meetingHosts.contains { url.host?.hasSuffix($0) == true }
        }
    }

    /// The next timed appointment that has not ended yet.
    var next: AgendaEvent? { events.first { !$0.allDay } }

    /// Starts within the next ten minutes or is running right now.
    var imminent: AgendaEvent? {
        guard let next, next.start.timeIntervalSinceNow < 10 * 60 else { return nil }
        return next
    }
}

extension AgendaEvent {
    /// "in 25 Min.", "läuft", "14:30" or "morgen 09:00".
    var when: String {
        let now = Date.now
        if allDay { return Calendar.current.isDateInToday(start) ? "ganztägig" : "morgen ganztägig" }
        if start <= now { return "läuft bis " + Self.clock(end) }
        let minutes = Int(start.timeIntervalSince(now) / 60)
        if minutes < 60 { return "in \(max(minutes, 1)) Min." }
        return (Calendar.current.isDateInToday(start) ? "" : "morgen ") + Self.clock(start)
    }

    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "de_DE")))
    }
}
