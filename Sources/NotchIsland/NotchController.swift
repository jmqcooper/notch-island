import AppKit
import SwiftUI

/// Owns the panel and decides when the island opens, closes, or turns into a drop target.
@MainActor
final class NotchController {
    let model: NotchModel

    private let panel = NotchPanel()
    private var screen: NSScreen?
    private var eventMonitor: Any?
    private var pollTimer: Timer?
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var isDragging = false
    /// After the island closes itself, wait for the pointer to leave before hover can reopen it.
    private var hoverSuppressed = false

    init() {
        model = NotchModel(
            music: MusicPlayer(),
            t3: T3Monitor(),
            shelf: ShelfStore(),
            printing: PrintStore(),
            calendar: CalendarMonitor(),
            dev: DevMonitor(),
            timer: FocusTimer(),
            camera: CameraMirror()
        )
        model.onClose = { [weak self] in self?.close(suppressHover: true) }
        wireEvents()

        let root = NotchRootView(model: model, music: model.music, t3: model.t3, timer: model.timer, calendar: model.calendar)
        let hosting = NotchHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.dropTarget = { [weak self] point in self?.dropTarget(at: point) }
        hosting.onDragTarget = { [weak self] target in self?.model.dropTarget = target }
        hosting.onDrop = { [weak self] urls, target in self?.handleDrop(urls, on: target) }
        panel.contentView = hosting
        layoutPanel()
        panel.orderFrontRegardless()

        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutPanel() }
        }
        installDebugHook()

        model.t3.start()
        model.calendar.start()
        model.dev.start()
        Task { await model.printing.refresh() }
    }

    func stop() {
        model.t3.stop()
        model.camera.stop()
    }

    // MARK: Events → notices

    private func wireEvents() {
        let model = self.model
        model.t3.onEvent = { [weak self] event in
            switch event {
            case .finished(let thread):
                self?.notify(Notice(tone: .success, symbol: "checkmark.circle.fill", title: thread.title,
                                    subtitle: "Done\(Self.duration(since: thread.startedAt)) · \(thread.place)",
                                    actionTitle: "Open", action: { model.t3.open(thread) }))
            case .failed(let thread):
                self?.notify(Notice(tone: .failure, symbol: "xmark.octagon.fill", title: thread.title,
                                    subtitle: "Failed · \(thread.place)",
                                    actionTitle: "Open", action: { model.t3.open(thread) }))
            case .needsInput(let thread):
                self?.notify(Notice(tone: .attention, symbol: "hand.raised.fill", title: thread.title,
                                    subtitle: thread.request?.questions.first?.text ?? "Needs you · \(thread.place)",
                                    actionTitle: "Answer", action: { [weak self] in self?.showQuestion(for: thread) }))
            }
        }
        model.calendar.onSoon = { [weak self] meeting in
            self?.notify(Notice(tone: .info, symbol: "calendar", title: meeting.title,
                                subtitle: "Starts \(meeting.start.formatted(date: .omitted, time: .shortened))" + (meeting.service.map { " · \($0)" } ?? ""),
                                actionTitle: meeting.joinURL == nil ? nil : "Join", action: { model.calendar.join(meeting) }))
        }
        model.timer.onFinish = { [weak self] duration in
            self?.notify(Notice(tone: .success, symbol: "timer", title: "Focus done",
                                subtitle: Int(duration / 60) == 1 ? "1 minute" : "\(Int(duration / 60)) minutes", actionTitle: "Again",
                                action: { model.timer.start(minutes: Int(duration / 60)) }))
        }
        model.dev.onEvent = { [weak self] event in
            switch event {
            case .checksFailed(let pull):
                self?.notify(Notice(tone: .failure, symbol: "xmark.octagon.fill", title: "#\(pull.number) checks failed",
                                    subtitle: "\(pull.repo) · \(pull.title)", actionTitle: "Open",
                                    action: { NSWorkspace.shared.open(pull.url) }))
            case .checksPassed(let pull):
                self?.notify(Notice(tone: .success, symbol: "checkmark.circle.fill", title: "#\(pull.number) checks passed",
                                    subtitle: "\(pull.repo) · \(pull.title)", actionTitle: "Open",
                                    action: { NSWorkspace.shared.open(pull.url) }))
            case .deployFailed(let deploy):
                self?.notify(Notice(tone: .failure, symbol: "xmark.octagon.fill", title: "\(deploy.project) / \(deploy.service) failed to deploy",
                                    subtitle: "Railway", actionTitle: deploy.url == nil ? nil : "Open",
                                    action: { deploy.url.map { _ = NSWorkspace.shared.open($0) } }))
            case .deployLive(let deploy):
                self?.notify(Notice(tone: .success, symbol: "checkmark.circle.fill", title: "\(deploy.project) / \(deploy.service) is live",
                                    subtitle: "Railway", actionTitle: deploy.url == nil ? nil : "Open",
                                    action: { deploy.url.map { _ = NSWorkspace.shared.open($0) } }))
            }
        }
    }

    /// Notices only show on the closed island; while it's open the same news is already on screen.
    private func notify(_ notice: Notice) {
        guard model.mode == .closed else { return }
        model.show(notice)
        updateMouseHandling()
    }

    private func showQuestion(for thread: T3Thread) {
        model.focusedThreadID = thread.id
        model.tab = .agents
        setMode(.open)
    }

    private static func duration(since start: Date?) -> String {
        guard let start else { return "" }
        let seconds = Date().timeIntervalSince(start)
        guard seconds >= 1 else { return "" }
        if seconds < 60 { return " in \(Int(seconds))s" }
        return " in " + Format.elapsed(seconds)
    }

    // MARK: Layout

    private func layoutPanel() {
        guard let geometry = NotchGeometry.current() else { return }
        screen = geometry.screen
        model.notchSize = geometry.notchSize
        let width = Metrics.openWidth + Metrics.windowPadding * 2
        let height = geometry.notchSize.height + Metrics.openBodyHeight + Metrics.windowPadding
        let frame = geometry.screen.frame
        panel.setFrame(
            NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height),
            display: true
        )
    }

    /// Screen rect for an island of the given size, hanging from the top centre.
    private func islandRect(_ size: CGSize) -> NSRect {
        guard let frame = screen?.frame else { return .zero }
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    // MARK: Pointer tracking

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            isDragging = false
        case .leftMouseDragged:
            // A real drag session writes to the drag pasteboard; dragging a window does not.
            if !isDragging, NSPasteboard(name: .drag).changeCount != dragChangeCount {
                isDragging = true
            }
        case .leftMouseUp:
            isDragging = false
            if model.mode == .drop { scheduleClose(after: 0.6) }
        default:
            break
        }
        evaluatePointer()
    }

    private func evaluatePointer() {
        let point = NSEvent.mouseLocation
        switch model.mode {
        case .closed:
            let hotZone = isDragging
                ? islandRect(model.hoverSize).insetBy(dx: -90, dy: -40)
                : islandRect(model.hoverSize).insetBy(dx: -4, dy: -2)
            guard hotZone.contains(point) else {
                hoverSuppressed = false
                cancelOpen()
                return
            }
            if !hoverSuppressed || isDragging {
                scheduleOpen(isDragging ? .drop : .open, after: isDragging ? 0 : 0.2)
            }
        case .open, .drop:
            if isDragging, model.mode == .open { setMode(.drop) }
            if model.holdOpen || islandRect(model.shapeSize).insetBy(dx: -12, dy: -12).contains(point) {
                cancelClose()
            } else {
                scheduleClose(after: isDragging ? 0.15 : 0.25)
            }
        }
    }

    private func scheduleOpen(_ mode: NotchModel.Mode, after delay: TimeInterval) {
        guard openWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.openWork = nil
            self.setMode(mode)
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelOpen() {
        openWork?.cancel()
        openWork = nil
    }

    private func scheduleClose(after delay: TimeInterval) {
        guard closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            self.setMode(.closed)
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }

    private func close(suppressHover: Bool) {
        hoverSuppressed = suppressHover
        cancelOpen()
        cancelClose()
        setMode(.closed)
    }

    private func setMode(_ mode: NotchModel.Mode) {
        guard model.mode != mode else { return }
        let wasClosed = model.mode == .closed
        model.mode = mode
        switch mode {
        case .closed:
            model.dropTarget = nil
            model.holdOpen = false
            if model.tab == .mirror { model.tab = .home }
            panel.resignKey()
            model.restorePinnedNotice()
        case .open, .drop:
            model.hideNotice()
            if mode == .open { model.music.refresh() }
            // The printer depends on where the Mac is, so look again for every drag.
            if mode == .drop { Task { await model.printing.refresh() } }
            if wasClosed {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
        updateMouseHandling()
    }

    /// The panel takes clicks only while it shows something clickable: the open island or a notice.
    private func updateMouseHandling() {
        let interactive = model.mode != .closed || model.notice != nil
        panel.ignoresMouseEvents = !interactive
        if interactive, pollTimer == nil {
            // The global monitor goes quiet while the pointer is over our own panel.
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if !interactive {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func tick() {
        if model.mode == .closed, model.notice == nil {
            updateMouseHandling()
            return
        }
        evaluatePointer()
    }

    // MARK: Drop

    /// While dragging, the island splits into thirds: AirDrop, shelf, print.
    /// The print third refuses drops when no printer is around.
    private func dropTarget(at point: NSPoint) -> DropTarget? {
        guard model.mode != .closed else { return nil }
        let island = islandRect(model.shapeSize).insetBy(dx: -8, dy: -8)
        guard island.contains(point) else { return nil }
        let third = island.width / 3
        if point.x < island.minX + third { return .airDrop }
        if point.x < island.minX + third * 2 { return .shelf }
        return model.printing.printer == nil ? nil : .print
    }

    private func handleDrop(_ urls: [URL], on target: DropTarget) {
        isDragging = false
        close(suppressHover: true)
        switch target {
        case .airDrop:
            if !AirDrop.send(urls) {
                notify(Notice(tone: .failure, symbol: "xmark.octagon.fill", title: "AirDrop isn't available",
                              subtitle: "Check that Wi-Fi and Bluetooth are on"))
            }
        case .shelf:
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return }
            model.shelf.add(files)
            let name = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
            notify(Notice(tone: .info, symbol: "tray.fill", title: "\(name) on the shelf",
                          subtitle: "Hover the notch and open Shelf to drag it back out"))
        case .print:
            // ⌥ while dropping prints in colour on one side, for photos.
            printFiles(urls, inColor: NSEvent.modifierFlags.contains(.option), hold: false)
        }
    }

    /// `hold` queues the job held, for tests that must not use paper.
    private func printFiles(_ urls: [URL], inColor: Bool, hold: Bool) {
        let printing = model.printing
        Task {
            for outcome in await printing.print(urls, inColor: inColor, hold: hold) {
                showPrintOutcome(outcome, hold: hold)
            }
        }
    }

    private func showPrintOutcome(_ outcome: PrintStore.Outcome, hold: Bool) {
        switch outcome {
        case .queued(let job, let title, let printer, let style):
            notify(Notice(tone: .info, symbol: "printer.fill", title: "Printing \(title)",
                          subtitle: "On \(printer) · \(style)", actionTitle: "Cancel",
                          action: { [weak self] in self?.cancelPrint(job, title: title) }))
        case .frontsQueued(_, let title, let sheets, let backs):
            // Stays until the backs are printed or it's closed: the fronts take a while.
            notify(Notice(tone: .attention, symbol: "printer.fill",
                          title: "Printing \(sheets) \(sheets == 1 ? "sheet" : "sheets") of \(title)",
                          subtitle: "Reload blank side up, top edge first",
                          actionTitle: "Print backs",
                          action: { [weak self] in self?.printBacks(backs, title: title, hold: hold) },
                          pinned: true))
        case .inApp(let title, let app):
            notify(Notice(tone: .info, symbol: "printer.fill", title: "Printing \(title) from \(app)",
                          subtitle: "Pick the printer in \(app)'s print dialog"))
        case .opened(let title, let app):
            notify(Notice(tone: .attention, symbol: "printer", title: "\(title) is open in \(app)",
                          subtitle: "\(app) couldn't be asked to print. Press ⌘P there"))
        case .failed(let message):
            notify(Notice(tone: .failure, symbol: "xmark.octagon.fill", title: "Couldn't print",
                          subtitle: message))
        }
    }

    private func printBacks(_ backs: URL, title: String, hold: Bool) {
        let printing = model.printing
        Task { showPrintOutcome(await printing.printBacks(backs, title: title, hold: hold), hold: hold) }
    }

    private func cancelPrint(_ job: String, title: String) {
        let printing = model.printing
        Task {
            let cancelled = await printing.cancel(job: job)
            notify(cancelled
                ? Notice(tone: .info, symbol: "printer", title: "Cancelled \(title)", subtitle: "Nothing more will print")
                : Notice(tone: .failure, symbol: "xmark.octagon.fill", title: "Couldn't cancel \(title)",
                         subtitle: "It may have printed already"))
        }
    }

    // MARK: Debug

    /// Lets scripts drive the island for screenshots and tests:
    /// `com.jmqcooper.NotchIsland.debug` with object "open:home", "open:agents", "drop", "drop:print", "close",
    /// "notice", "print-held:<path>" (prints held, never on paper), "print-held-colour:<path>" or "notice-action".
    private func installDebugHook() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.jmqcooper.NotchIsland.debug"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.runDebug(command) }
        }
    }

    private func runDebug(_ command: String) {
        let parts = command.split(separator: ":").map(String.init)
        switch parts.first {
        case "open":
            if let name = parts.dropFirst().first, let tab = NotchTab(rawValue: name) { model.tab = tab }
            if parts.count > 2 { model.focusedThreadID = parts[2...].joined(separator: ":") }
            hoverSuppressed = true
            setMode(.open)
            model.holdOpen = true
        case "drop":
            setMode(.drop)
            model.holdOpen = true
            if parts.dropFirst().first == "print" { model.dropTarget = .print }
        case "close":
            close(suppressHover: false)
        case "notice":
            notify(Notice(tone: .success, symbol: "checkmark.circle.fill", title: "Fix the login redirect",
                          subtitle: "Done in 54s · Mac", actionTitle: "Open", action: { T3App.activate() }))
        case "timer":
            model.timer.start(minutes: Int(parts.dropFirst().first ?? "") ?? 25)
        case "print-held", "print-held-colour":
            let path = parts.dropFirst().joined(separator: ":")
            guard !path.isEmpty else { return }
            close(suppressHover: false)
            printFiles([URL(fileURLWithPath: path)], inColor: parts[0] == "print-held-colour", hold: true)
        case "notice-action":
            // Same as pressing the notice's button.
            guard let notice = model.notice else { return }
            notice.action?()
            model.dismissNotice()
        default:
            break
        }
    }
}

@MainActor
enum AirDrop {
    static var icon: NSImage? { NSSharingService(named: .sendViaAirDrop)?.image }

    static func send(_ urls: [URL]) -> Bool {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            return false
        }
        NSApp.activate()
        service.perform(withItems: urls)
        return true
    }
}
