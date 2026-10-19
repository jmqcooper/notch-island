import AppKit
import SwiftUI

/// A short notice that slides out under the notch, like a Live Activity alert.
struct Notice: Identifiable, Equatable {
    enum Tone: Equatable {
        case success
        case failure
        case attention
        case info
    }

    let id = UUID()
    let tone: Tone
    let symbol: String
    let title: String
    let subtitle: String
    var actionTitle: String?
    var action: (() -> Void)?
    /// Waits for the user instead of fading out: it comes back after other notices and
    /// after the island closes, and has a close button.
    var pinned = false

    static func == (left: Notice, right: Notice) -> Bool { left.id == right.id }
}

enum NotchTab: String, CaseIterable, Identifiable {
    case home
    case agents
    case shelf
    case mirror

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .agents: return "sparkle"
        case .shelf: return "tray"
        case .mirror: return "camera"
        }
    }
}

enum DropTarget: Equatable {
    case airDrop
    case shelf
    case print
}

/// Left side of the closed island: what's playing.
enum LeftLane: Equatable {
    case none
    case artwork
    case timer
}

/// Right side of the closed island: what needs attention, most urgent first.
enum RightLane: Equatable {
    case none
    case needsYou(Int)
    case meeting(minutes: Int)
    case working(Int)
    case finished(success: Bool)
    case equalizer
}

@MainActor
final class NotchModel: ObservableObject {
    enum Mode: Equatable {
        case closed
        case open
        case drop
    }

    @Published var mode: Mode = .closed
    @Published var tab: NotchTab = .home
    @Published var notice: Notice?
    @Published var dropTarget: DropTarget?
    @Published var notchSize = CGSize(width: 185, height: 32)
    /// The thread whose question is shown on the Agents tab.
    @Published var focusedThreadID: String?
    /// Keeps the island open while an answer is being typed.
    @Published var holdOpen = false

    let music: MusicPlayer
    let t3: T3Monitor
    let shelf: ShelfStore
    let printing: PrintStore
    let calendar: CalendarMonitor
    let dev: DevMonitor
    let timer: FocusTimer
    let camera: CameraMirror

    var onClose: () -> Void = {}

    private var noticeDismissal: DispatchWorkItem?
    private var pinnedNotice: Notice?

    init(music: MusicPlayer, t3: T3Monitor, shelf: ShelfStore, printing: PrintStore, calendar: CalendarMonitor, dev: DevMonitor, timer: FocusTimer, camera: CameraMirror) {
        self.music = music
        self.t3 = t3
        self.shelf = shelf
        self.printing = printing
        self.calendar = calendar
        self.dev = dev
        self.timer = timer
        self.camera = camera
    }

    // MARK: Closed lanes

    var leftLane: LeftLane {
        if timer.isActive { return .timer }
        if music.isPlaying { return .artwork }
        return .none
    }

    var rightLane: RightLane {
        if t3.needsInputCount > 0 { return .needsYou(t3.needsInputCount) }
        if let meeting = calendar.next {
            let minutes = Int((meeting.start.timeIntervalSinceNow / 60).rounded(.up))
            if (-5...10).contains(minutes) { return .meeting(minutes: max(0, minutes)) }
        }
        if t3.workingCount > 0 { return .working(t3.workingCount) }
        if let flash = t3.flash { return .finished(success: flash) }
        if music.isPlaying { return .equalizer }
        return .none
    }

    var showsWings: Bool { leftLane != .none || rightLane != .none || notice != nil }

    var wingWidth: CGFloat {
        switch (leftLane, rightLane) {
        case (.timer, _), (_, .needsYou), (_, .meeting), (_, .working): return 52
        default: return 38
        }
    }

    // MARK: Geometry

    /// Size of the black island, including the fillets at the top corners.
    var shapeSize: CGSize {
        switch mode {
        case .open:
            return CGSize(width: Metrics.openWidth, height: notchSize.height + Metrics.openBodyHeight)
        case .drop:
            return CGSize(width: Metrics.dropWidth, height: notchSize.height + Metrics.dropBodyHeight)
        case .closed:
            let width = notchSize.width + (showsWings ? wingWidth * 2 : 0)
            guard notice != nil else { return CGSize(width: width, height: notchSize.height) }
            return CGSize(width: max(width, Metrics.noticeWidth), height: notchSize.height + Metrics.noticeHeight)
        }
    }

    /// The part of the closed island that opens on hover: the notch and its wings, never the notice.
    var hoverSize: CGSize {
        CGSize(width: notchSize.width + (showsWings ? wingWidth * 2 : 0), height: notchSize.height)
    }

    var topRadius: CGFloat {
        switch mode {
        case .closed: return 6
        case .open, .drop: return 14
        }
    }

    var bottomRadius: CGFloat {
        switch mode {
        case .closed: return notice == nil ? 14 : 22
        case .open, .drop: return 28
        }
    }

    // MARK: Notices

    func show(_ notice: Notice) {
        self.notice = notice
        noticeDismissal?.cancel()
        if notice.pinned {
            pinnedNotice = notice
            return
        }
        let dismissal = DispatchWorkItem { [weak self] in self?.notice = self?.pinnedNotice }
        noticeDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: dismissal)
    }

    /// Closes the notice for good. A pinned notice underneath comes back.
    func dismissNotice() {
        noticeDismissal?.cancel()
        if notice?.id == pinnedNotice?.id { pinnedNotice = nil }
        notice = pinnedNotice
    }

    /// Hides the notice while the island is open; `restorePinnedNotice` brings a pinned one back.
    func hideNotice() {
        noticeDismissal?.cancel()
        notice = nil
    }

    func restorePinnedNotice() {
        if notice == nil { notice = pinnedNotice }
    }

    var focusedThread: T3Thread? {
        focusedThreadID.flatMap(t3.thread(withID:)).flatMap { $0.state == .needsInput ? $0 : nil }
    }
}
