import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var music: MusicPlayer
    @ObservedObject var t3: T3Monitor
    @ObservedObject var timer: FocusTimer
    @ObservedObject var calendar: CalendarMonitor

    private let openSpring = Animation.spring(response: 0.42, dampingFraction: 0.8)
    private let closeSpring = Animation.spring(response: 0.45, dampingFraction: 1.0)

    var body: some View {
        let size = model.shapeSize
        let spring = model.mode == .closed ? closeSpring : openSpring
        ZStack(alignment: .top) {
            Color.black
            content
                .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(NotchShape(topRadius: model.topRadius, bottomRadius: model.bottomRadius))
        .shadow(color: .black.opacity(model.mode == .closed && model.notice == nil ? 0 : 0.5), radius: 14, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(spring, value: size)
        .animation(spring, value: model.mode)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .closed:
            ClosedView(model: model, music: music, timer: timer)
                .transition(.opacity)
        case .open:
            OpenView(model: model, t3: t3, shelf: model.shelf)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        case .drop:
            DropView(model: model, shelf: model.shelf, printing: model.printing)
                .transition(.opacity)
        }
    }
}

/// The resting island: invisible inside the notch, with wings when something is live.
/// Left is what's playing, right is what needs attention.
struct ClosedView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var music: MusicPlayer
    @ObservedObject var timer: FocusTimer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                left.frame(width: model.wingWidth)
                Spacer(minLength: 0)
                right.frame(width: model.wingWidth)
            }
            .frame(height: model.notchSize.height)
            .padding(.horizontal, 6)

            if let notice = model.notice {
                NoticeView(notice: notice, dismiss: model.dismissNotice)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var left: some View {
        switch model.leftLane {
        case .artwork:
            Artwork(image: music.artwork, size: 20, cornerRadius: 5)
        case .timer:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Format.clock(timer.remaining(at: context.date).rounded(.up)))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.yellow.opacity(timer.isPaused ? 0.5 : 1))
            }
        case .none:
            Color.clear
        }
    }

    @ViewBuilder
    private var right: some View {
        switch model.rightLane {
        case .needsYou(let count):
            HStack(spacing: 4) {
                PulsingDot(color: Palette.orange)
                Text("\(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.orange)
            }
        case .meeting(let minutes):
            HStack(spacing: 3) {
                Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
                Text(minutes == 0 ? "now" : "\(minutes)m").font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(Palette.blue)
        case .working(let count):
            HStack(spacing: 4) {
                Spinner(color: Palette.cyan)
                Text("\(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.cyan)
            }
        case .finished(let success):
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 14))
                .foregroundStyle(success ? Palette.green : Palette.red)
        case .equalizer:
            Equalizer()
        case .none:
            Color.clear
        }
    }
}

struct NoticeView: View {
    let notice: Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.symbol)
                .font(.system(size: 20))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(notice.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let title = notice.actionTitle {
                PillButton(title: title, tint: nil) {
                    notice.action?()
                    dismiss()
                }
            }
            if notice.pinned {
                IconButton(symbol: "xmark", action: dismiss)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: Metrics.noticeHeight - 8)
    }

    private var color: Color {
        switch notice.tone {
        case .success: return Palette.green
        case .failure: return Palette.red
        case .attention: return Palette.orange
        case .info: return Palette.blue
        }
    }
}

/// Shown while a file is dragged near the notch: send it now, park it on the shelf, or print it here.
struct DropView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var printing: PrintStore

    var body: some View {
        HStack(spacing: 10) {
            zone(.airDrop) {
                AirDropIcon(size: 40)
            } title: {
                "AirDrop"
            } subtitle: {
                model.dropTarget == .airDrop ? "Pick a device" : "Send now"
            }
            zone(.shelf) {
                Image(systemName: "tray")
                    .font(.system(size: 18))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } title: {
                "Shelf"
            } subtitle: {
                shelf.items.isEmpty ? "Keep for later" : "Keep · \(shelf.items.count) \(shelf.items.count == 1 ? "file" : "files")"
            }
            zone(.print, enabled: printing.printer != nil) {
                Image(systemName: "printer")
                    .font(.system(size: 18))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } title: {
                "Print"
            } subtitle: {
                guard let printer = printing.printer else { return "No printer here" }
                return model.dropTarget == .print ? "B&W 2-sided · ⌥ colour" : printer.name
            }
        }
        .padding(.top, model.notchSize.height + 6)
        .padding(.horizontal, 34)
        .padding(.bottom, 18)
        .animation(.easeOut(duration: 0.15), value: model.dropTarget)
    }

    private func zone<Icon: View>(
        _ target: DropTarget,
        enabled: Bool = true,
        @ViewBuilder icon: () -> Icon,
        title: () -> String,
        subtitle: () -> String
    ) -> some View {
        let targeted = model.dropTarget == target
        return HStack(spacing: 12) {
            icon()
            VStack(alignment: .leading, spacing: 2) {
                Text(title()).font(.system(size: 14, weight: .semibold))
                Text(subtitle())
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(targeted ? Palette.blue.opacity(0.18) : Color.white.opacity(0.001))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(targeted ? Palette.blue : Color.white.opacity(0.3))
        )
        .opacity(enabled ? 1 : 0.4)
    }
}
