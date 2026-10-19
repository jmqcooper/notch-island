import SwiftUI

enum Palette {
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.42)
    static let fill = Color.white.opacity(0.07)
    static let cyan = Color(red: 0.39, green: 0.82, blue: 1.0)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let yellow = Color(red: 1.0, green: 0.84, blue: 0.04)
    static let purple = Color(red: 0.75, green: 0.35, blue: 0.95)
}

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(Palette.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A rounded row on Home: icon, two lines, and an action on the right.
struct LiveRow<Icon: View, Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            icon()
                .font(.system(size: 14))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            accessory()
        }
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .frame(height: 42)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct PillButton: View {
    let title: String
    let tint: Color?
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(filled ? .white : (tint ?? .white))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        if filled { return tint ?? Color.white.opacity(0.2) }
        return (tint ?? .white).opacity(tint == nil ? 0.1 : 0.18)
    }
}

struct IconButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ChoiceChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(selected ? Palette.blue.opacity(0.35) : Color.white.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TabButton: View {
    let tab: NotchTab
    let selected: Bool
    let badge: Bool
    let count: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: tab.symbol).font(.system(size: 12, weight: .medium))
                if let count { Text("\(count)").font(.system(size: 10, weight: .semibold)) }
            }
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.6))
            .padding(.horizontal, 8)
            .frame(minWidth: 30, minHeight: 24)
            .background(selected ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if badge {
                    Circle().fill(Palette.orange).frame(width: 6, height: 6).offset(x: -4, y: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct EmptyLine: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }
        .padding(.leading, 6)
        .padding(.vertical, 6)
    }
}

struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.tertiary)
            .padding(.leading, 6)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

struct T3Row: View {
    let thread: T3Thread
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            StatusGlyph(state: thread.state)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(thread.place)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(status(at: context.date))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(color)
            }
        }
        .rowStyle(hovering: hovering)
        .onHover { hovering = $0 }
    }

    private func status(at date: Date) -> String {
        let age = thread.since.map { Format.elapsed(date.timeIntervalSince($0)) } ?? ""
        switch thread.state {
        case .needsInput: return "Answer"
        case .working: return age
        case .queued: return "Queued"
        case .completed: return age == "now" ? "Done" : "Done \(age) ago"
        case .failed: return "Failed"
        }
    }

    private var color: Color {
        switch thread.state {
        case .needsInput: return Palette.orange
        case .working: return Palette.cyan
        case .queued: return Palette.tertiary
        case .completed: return Palette.green
        case .failed: return Palette.red
        }
    }
}

struct PullRow: View {
    let pull: DevMonitor.PullRequest
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Group {
                switch pull.checks {
                case .passing: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
                case .failing: Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.red)
                case .pending: Spinner(color: Palette.yellow)
                case .none: Image(systemName: "arrow.triangle.pull").foregroundStyle(Palette.tertiary)
                }
            }
            .font(.system(size: 12))
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text("#\(pull.number) \(pull.title)").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(pull.repo).font(.system(size: 10)).foregroundStyle(Palette.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .rowStyle(hovering: hovering)
        .onHover { hovering = $0 }
    }
}

struct DeployRow: View {
    let deploy: DevMonitor.Deploy
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Group {
                switch deploy.status {
                case .building: Spinner(color: Palette.purple)
                case .live: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.red)
                case .idle: Image(systemName: "moon.fill").foregroundStyle(Palette.tertiary)
                }
            }
            .font(.system(size: 12))
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(deploy.project) / \(deploy.service)").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("Railway").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
            }
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(label(at: context.date))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.tertiary)
            }
        }
        .rowStyle(hovering: hovering)
        .onHover { hovering = $0 }
    }

    private func label(at date: Date) -> String {
        let age = Format.elapsed(date.timeIntervalSince(deploy.createdAt))
        switch deploy.status {
        case .building: return "Deploying · \(age)"
        case .live: return "Live · \(age) ago"
        case .failed: return "Failed · \(age) ago"
        case .idle: return "Asleep"
        }
    }
}

private extension View {
    func rowStyle(hovering: Bool) -> some View {
        padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
    }
}

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AirDropIcon: View {
    let size: CGFloat

    var body: some View {
        if let icon = AirDrop.icon {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: size * 0.6))
                .frame(width: size, height: size)
        }
    }
}

struct StatusGlyph: View {
    let state: T3Thread.State

    var body: some View {
        switch state {
        case .needsInput:
            PulsingDot(color: Palette.orange)
        case .working:
            Spinner(color: Palette.cyan)
        case .queued:
            Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
        case .completed:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Palette.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").font(.system(size: 12)).foregroundStyle(Palette.red)
        }
    }
}

struct Spinner: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
            let turns = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turns * 360))
        }
        .frame(width: 11, height: 11)
    }
}

struct PulsingDot: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let pulse = (sin(context.date.timeIntervalSinceReferenceDate * 4) + 1) / 2
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .stroke(color.opacity(0.6 * (1 - pulse)), lineWidth: 1.5)
                        .scaleEffect(1 + pulse)
                )
        }
        .frame(width: 14, height: 14)
    }
}

struct Equalizer: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    let phase = time * (2.6 + Double(index) * 0.7) + Double(index)
                    Capsule().frame(width: 2.5, height: 4 + 9 * abs(sin(phase)))
                }
            }
            .animation(.easeInOut(duration: 0.08), value: time)
            .foregroundStyle(Color.white.opacity(0.88))
        }
        .frame(height: 14)
    }
}

enum Format {
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "now" }
        if total < 3600 { return "\(total / 60)m" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }
}
