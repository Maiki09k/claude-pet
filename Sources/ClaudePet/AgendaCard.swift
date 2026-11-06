import SwiftUI

/// Today's appointments on the desktop, under the Claude card.
struct AgendaCard: View {
    let events: [AgendaEvent]
    let access: Agenda.Access
    let onlyLocalCalendars: Bool
    var glass = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Termine")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "de_DE"))))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            TimelineView(.everyMinute) { _ in rows }
                .padding(.top, 16)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: WidgetMetrics.agenda.width, height: WidgetMetrics.agenda.height, alignment: .topLeading)
        .cardChrome(glass: glass)
    }

    @ViewBuilder private var rows: some View {
        switch access {
        case .unknown:
            hint("Kalender wird geladen …")
        case .denied:
            hint("Kalender freigeben: Systemeinstellungen › Datenschutz und Sicherheit › Kalender › Claude Pet")
        case .granted:
            if events.isEmpty {
                hint(onlyLocalCalendars
                     ? "Kein Google-Kalender gefunden. Konto hinzufügen: Systemeinstellungen › Internetaccounts."
                     : "Heute und morgen steht nichts mehr an.")
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(events.prefix(4)) { row($0, isNext: $0 == events.first { !$0.allDay }) }
                }
            }
        }
    }

    private func row(_ event: AgendaEvent, isNext: Bool) -> some View {
        HStack(spacing: 10) {
            Text(time(event))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Capsule().fill(event.color).frame(width: 3, height: 16)
            Text(event.title)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if isNext, let badge = badge(event) {
                Text(badge.0)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(badge.1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            }
        }
    }

    private func time(_ event: AgendaEvent) -> String {
        let today = Calendar.current.isDateInToday(event.start)
        let weekday = event.start.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "de_DE")))
        if event.allDay { return today ? "ganztags" : weekday }
        let clock = AgendaEvent.clock(event.start)
        return today ? clock : weekday + " " + clock
    }

    /// Only the next appointment gets a countdown, and only within two hours.
    private func badge(_ event: AgendaEvent) -> (String, Color)? {
        let seconds = event.start.timeIntervalSinceNow
        if seconds <= 0 { return ("läuft", Color(hex: 0x2FB57A)) }
        if seconds < 2 * 3600 { return ("in \(max(Int(seconds / 60), 1)) Min.", .primary) }
        return nil
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
