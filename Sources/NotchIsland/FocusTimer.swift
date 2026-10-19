import AppKit

@MainActor
final class FocusTimer: ObservableObject {
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var duration: TimeInterval = 0
    var onFinish: (TimeInterval) -> Void = { _ in }

    private var completion: DispatchSourceTimer?

    var isActive: Bool { endDate != nil || pausedRemaining != nil }
    var isPaused: Bool { pausedRemaining != nil }

    func remaining(at date: Date = Date()) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSince(date))
    }

    func start(minutes: Int) {
        duration = TimeInterval(minutes * 60)
        pausedRemaining = nil
        schedule(endingAt: Date().addingTimeInterval(duration))
    }

    func togglePause() {
        if let pausedRemaining {
            self.pausedRemaining = nil
            schedule(endingAt: Date().addingTimeInterval(pausedRemaining))
        } else if endDate != nil {
            pausedRemaining = remaining()
            endDate = nil
            completion?.cancel()
        }
    }

    func stop() {
        completion?.cancel()
        endDate = nil
        pausedRemaining = nil
    }

    private func schedule(endingAt date: Date) {
        endDate = date
        completion?.cancel()
        // A strict timer: plain asyncAfter can land seconds late when macOS coalesces timers.
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(wallDeadline: .now() + date.timeIntervalSinceNow, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let duration = self.duration
                self.stop()
                NSSound(named: "Glass")?.play()
                self.onFinish(duration)
            }
        }
        completion = timer
        timer.resume()
    }
}
