import AppKit
import EventKit

/// Next meeting from the calendars on this Mac, with a join link when one can be found.
@MainActor
final class CalendarMonitor: ObservableObject {
    struct Meeting: Equatable, Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let joinURL: URL?
        let service: String?
    }

    @Published private(set) var next: Meeting?
    var onSoon: (Meeting) -> Void = { _ in }

    private let store = EKEventStore()
    private var timer: Timer?
    private var announced: Set<String> = []

    private static let meetingHosts: [(suffix: String, name: String)] = [
        ("meet.google.com", "Google Meet"),
        ("zoom.us", "Zoom"),
        ("teams.microsoft.com", "Teams"),
        ("teams.live.com", "Teams"),
        ("webex.com", "Webex"),
        ("whereby.com", "Whereby"),
        ("meet.jit.si", "Jitsi"),
        ("facetime.apple.com", "FaceTime"),
        ("around.co", "Around"),
    ]

    func start() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task {
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                _ = try? await store.requestFullAccessToEvents()
            }
            let status = EKEventStore.authorizationStatus(for: .event)
            Log.write("calendar access: \(status == .fullAccess ? "granted" : "not granted (\(status.rawValue))"), calendars: \(store.calendars(for: .event).count)")
            refresh()
        }
    }

    func refresh() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            next = nil
            return
        }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(12 * 3600), calendars: nil)
        let upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && !Self.isDeclined($0) }
            .sorted { $0.startDate < $1.startDate }
        guard let event = upcoming.first else {
            next = nil
            return
        }
        let link = Self.joinLink(for: event)
        let meeting = Meeting(
            id: event.eventIdentifier ?? event.calendarItemIdentifier,
            title: event.title ?? "Untitled",
            start: event.startDate,
            end: event.endDate,
            joinURL: link?.url,
            service: link?.service
        )
        next = meeting
        let minutes = meeting.start.timeIntervalSince(now) / 60
        if minutes <= 5, minutes > -1, !announced.contains(meeting.id) {
            announced.insert(meeting.id)
            onSoon(meeting)
        }
    }

    func join(_ meeting: Meeting) {
        if let url = meeting.joinURL { NSWorkspace.shared.open(url) }
    }

    private static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    /// Checks the event URL, then location, then notes, keeping only known meeting hosts.
    private static func joinLink(for event: EKEvent) -> (url: URL, service: String)? {
        var candidates: [URL] = []
        if let url = event.url { candidates.append(url) }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for text in [event.location, event.notes].compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            candidates += detector?.matches(in: text, range: range).compactMap(\.url) ?? []
        }
        for url in candidates {
            guard let host = url.host?.lowercased() else { continue }
            if let match = meetingHosts.first(where: { host == $0.suffix || host.hasSuffix("." + $0.suffix) }) {
                return (url, match.name)
            }
        }
        return nil
    }
}
