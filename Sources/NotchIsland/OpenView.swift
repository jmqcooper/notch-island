import SwiftUI

/// The hover state: tabs in the menu bar band, the selected page below.
struct OpenView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var t3: T3Monitor
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(NotchTab.allCases) { tab in
                    TabButton(tab: tab, selected: model.tab == tab, badge: badge(for: tab), count: count(for: tab)) {
                        model.tab = tab
                    }
                }
                Spacer()
                Menu {
                    Button(LoginItem.isEnabled ? "Don't Open at Login" : "Open at Login") { LoginItem.toggle() }
                    Divider()
                    Button("Quit NotchIsland") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 26)
            .frame(height: model.notchSize.height)

            Group {
                switch model.tab {
                case .home: HomeTab(model: model, music: model.music, t3: t3, calendar: model.calendar, dev: model.dev, timer: model.timer)
                case .agents: AgentsTab(model: model, t3: t3, dev: model.dev)
                case .shelf: ShelfTab(model: model, shelf: shelf)
                case .mirror: MirrorTab(camera: model.camera)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 30)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }

    private func badge(for tab: NotchTab) -> Bool {
        tab == .agents && t3.needsInputCount > 0
    }

    private func count(for tab: NotchTab) -> Int? {
        tab == .shelf && !shelf.items.isEmpty ? shelf.items.count : nil
    }
}

// MARK: Home

struct HomeTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var music: MusicPlayer
    @ObservedObject var t3: T3Monitor
    @ObservedObject var calendar: CalendarMonitor
    @ObservedObject var dev: DevMonitor
    @ObservedObject var timer: FocusTimer

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            MusicCard(music: music)
                .frame(width: 268)
            VStack(spacing: 6) {
                ForEach(Array(rows.prefix(3).enumerated()), id: \.offset) { _, row in row }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Live rows, most urgent first. Home shows the top three.
    private var rows: [AnyView] {
        var rows: [AnyView] = []
        for thread in t3.threads where thread.state == .needsInput {
            rows.append(AnyView(LiveRow(title: thread.title, subtitle: "\(thread.place) · \(thread.request?.summary ?? "Waiting for you")") {
                PulsingDot(color: Palette.orange)
            } accessory: {
                PillButton(title: "Answer", tint: Palette.orange) {
                    model.focusedThreadID = thread.id
                    model.tab = .agents
                }
            }))
        }
        if let meeting = calendar.next, meeting.start.timeIntervalSinceNow < 2 * 3600 {
            rows.append(AnyView(LiveRow(title: meeting.title, subtitle: meetingSubtitle(meeting)) {
                Image(systemName: "calendar").foregroundStyle(Palette.blue)
            } accessory: {
                if meeting.joinURL != nil {
                    PillButton(title: "Join", tint: Palette.blue, filled: true) {
                        calendar.join(meeting)
                        model.onClose()
                    }
                }
            }))
        }
        if timer.isActive {
            rows.append(AnyView(TimerRow(timer: timer)))
        }
        for pull in dev.failingPulls.prefix(1) {
            rows.append(AnyView(LiveRow(title: "#\(pull.number) checks failed", subtitle: "\(pull.repo) · \(pull.title)") {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.red)
            } accessory: {
                PillButton(title: "Open", tint: nil) { NSWorkspace.shared.open(pull.url) }
            }))
        }
        for deploy in dev.buildingDeploys.prefix(1) {
            rows.append(AnyView(LiveRow(title: "\(deploy.project) / \(deploy.service)", subtitle: "Deploying on Railway") {
                Spinner(color: Palette.purple)
            } accessory: {
                if let url = deploy.url { PillButton(title: "Open", tint: nil) { NSWorkspace.shared.open(url) } }
            }))
        }
        let working = t3.threads.filter { $0.state == .working || $0.state == .queued }
        if let first = working.first {
            let title = working.count == 1 ? first.title : "\(working.count) agents working"
            rows.append(AnyView(LiveRow(title: title, subtitle: working.count == 1 ? first.place : working.map(\.title).joined(separator: ", ")) {
                Spinner(color: Palette.cyan)
            } accessory: {
                PillButton(title: "View", tint: nil) { model.tab = .agents }
            }))
        }
        if !timer.isActive {
            rows.append(AnyView(LiveRow(title: "Focus timer", subtitle: "Shows in the notch while it runs") {
                Image(systemName: "timer").foregroundStyle(Palette.yellow)
            } accessory: {
                HStack(spacing: 4) {
                    ForEach([15, 25, 50], id: \.self) { minutes in
                        PillButton(title: "\(minutes)", tint: nil) { timer.start(minutes: minutes) }
                    }
                }
            }))
        }
        return rows
    }

    private func meetingSubtitle(_ meeting: CalendarMonitor.Meeting) -> String {
        let minutes = Int((meeting.start.timeIntervalSinceNow / 60).rounded(.up))
        let when: String
        if minutes <= 0 {
            when = "now"
        } else if minutes < 60 {
            when = "in \(minutes) min"
        } else {
            when = "at " + meeting.start.formatted(date: .omitted, time: .shortened)
        }
        return [when, meeting.service].compactMap { $0 }.joined(separator: " · ")
    }
}

struct TimerRow: View {
    @ObservedObject var timer: FocusTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = Format.clock(timer.remaining(at: context.date).rounded(.up))
            LiveRow(title: "Focus", subtitle: timer.isPaused ? "Paused · \(remaining) left" : "\(remaining) left") {
                Image(systemName: "timer").foregroundStyle(Palette.yellow)
            } accessory: {
                HStack(spacing: 4) {
                    IconButton(symbol: timer.isPaused ? "play.fill" : "pause.fill") { timer.togglePause() }
                    IconButton(symbol: "xmark") { timer.stop() }
                }
            }
        }
    }
}

struct MusicCard: View {
    @ObservedObject var music: MusicPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Artwork(image: music.artwork, size: 56, cornerRadius: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(music.track?.title ?? "Nothing playing")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(music.track?.artist ?? "Press play to start Spotify")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                    if let source = music.source {
                        Text(source.name)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.tertiary)
                    }
                }
            }
            if music.track != nil {
                TrackProgress(music: music).padding(.top, 12)
            }
            HStack(spacing: 30) {
                ControlButton(symbol: "backward.fill", size: 15) { music.previous() }
                    .disabled(music.source == nil)
                ControlButton(symbol: music.isPlaying ? "pause.fill" : "play.fill", size: 19) { music.playPause() }
                ControlButton(symbol: "forward.fill", size: 15) { music.next() }
                    .disabled(music.source == nil)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, music.track == nil ? 14 : 4)
        }
    }
}

struct TrackProgress: View {
    @ObservedObject var music: MusicPlayer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = music.track?.duration ?? 0
            let position = music.position(at: context.date)
            VStack(spacing: 3) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule()
                            .fill(Color.white.opacity(0.88))
                            .frame(width: duration > 0 ? geometry.size.width * min(1, position / duration) : 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard duration > 0 else { return }
                        music.seek(to: duration * location.x / geometry.size.width)
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(Format.clock(position))
                    Spacer()
                    Text(duration > 0 ? Format.clock(duration) : "")
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Palette.tertiary)
            }
        }
    }
}

// MARK: Agents

struct AgentsTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var t3: T3Monitor
    @ObservedObject var dev: DevMonitor

    var body: some View {
        if let thread = model.focusedThread, let request = thread.request {
            QuestionView(model: model, thread: thread, request: request)
                .id(request.id)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    if t3.threads.isEmpty {
                        EmptyLine(title: "No agents running", detail: "Finished threads stay here for 30 minutes")
                    }
                    ForEach(t3.threads) { thread in
                        Button {
                            if thread.state == .needsInput, thread.request != nil {
                                model.focusedThreadID = thread.id
                            } else {
                                t3.open(thread)
                                model.onClose()
                            }
                        } label: {
                            T3Row(thread: thread)
                        }
                        .buttonStyle(.plain)
                    }
                    if !dev.pulls.isEmpty || !dev.deploys.isEmpty {
                        SectionLabel(title: "Pull requests and deploys")
                        ForEach(dev.deploys) { deploy in
                            Button { if let url = deploy.url { NSWorkspace.shared.open(url) } } label: { DeployRow(deploy: deploy) }
                                .buttonStyle(.plain)
                        }
                        ForEach(dev.pulls) { pull in
                            Button { NSWorkspace.shared.open(pull.url) } label: { PullRow(pull: pull) }
                                .buttonStyle(.plain)
                        }
                    }
                    if !t3.offlineHosts.isEmpty {
                        Text("Can't reach \(t3.offlineHosts.joined(separator: ", "))")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.orange.opacity(0.85))
                            .padding(.leading, 6)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }
}

/// Answer an agent's question, or approve a request, without leaving the notch.
struct QuestionView: View {
    @ObservedObject var model: NotchModel
    let thread: T3Thread
    let request: T3Request

    @State private var index = 0
    @State private var answers: [String: String] = [:]
    @State private var selected: [String] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconButton(symbol: "chevron.left") { model.focusedThreadID = nil }
                VStack(alignment: .leading, spacing: 0) {
                    Text(thread.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(progressLabel).font(.system(size: 10)).foregroundStyle(Palette.tertiary).lineLimit(1)
                }
                Spacer()
                PillButton(title: "Open in T3", tint: nil) {
                    model.t3.open(thread)
                    model.onClose()
                }
            }
            if request.isApproval {
                approval
            } else if request.questions.indices.contains(index) {
                question(request.questions[index])
            } else {
                Text("This request can only be answered in T3.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
            }
            if let error {
                Text(error).font(.system(size: 10)).foregroundStyle(Palette.red).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .disabled(sending)
        .opacity(sending ? 0.6 : 1)
        .onChange(of: draft) { _, value in model.holdOpen = !value.isEmpty }
        .onDisappear { model.holdOpen = false }
    }

    private var progressLabel: String {
        let count = request.questions.count
        return count > 1 ? "\(thread.place) · question \(index + 1) of \(count)" : thread.place
    }

    private func question(_ question: T3Request.Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !question.options.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(question.options, id: \.value) { option in
                            ChoiceChip(title: option.label, selected: selected.contains(option.value)) {
                                choose(option, in: question)
                            }
                            .help(option.detail)
                        }
                        if question.multiSelect {
                            PillButton(title: "Next", tint: Palette.blue, filled: true) {
                                submit(selected.joined(separator: ", "), for: question)
                            }
                            .disabled(selected.isEmpty)
                        }
                    }
                }
            }
            if question.allowsCustom {
                HStack(spacing: 6) {
                    TextField(question.options.isEmpty ? "Type your answer" : "Or type an answer", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onSubmit { sendDraft(for: question) }
                    PillButton(title: sending ? "Sending…" : "Send", tint: Palette.blue, filled: true) {
                        sendDraft(for: question)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var approval: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.prompt.isEmpty ? "The agent is asking for permission." : request.prompt)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                ForEach(request.choices, id: \.decision) { choice in
                    PillButton(title: choice.label, tint: choice.decision == "accept" ? Palette.blue : nil, filled: choice.decision == "accept") {
                        decide(choice.decision)
                    }
                }
            }
        }
    }

    private func choose(_ option: T3Request.Option, in question: T3Request.Question) {
        if question.multiSelect {
            if let position = selected.firstIndex(of: option.value) {
                selected.remove(at: position)
            } else {
                selected.append(option.value)
            }
        } else {
            submit(option.value, for: question)
        }
    }

    private func sendDraft(for question: T3Request.Question) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        submit(text, for: question)
    }

    private func submit(_ answer: String, for question: T3Request.Question) {
        answers[question.id] = answer
        draft = ""
        selected = []
        if index + 1 < request.questions.count {
            index += 1
        } else {
            send { try await model.t3.answer(thread, answers: answers) }
        }
    }

    private func decide(_ decision: String) {
        send { try await model.t3.decide(thread, decision: decision) }
    }

    private func send(_ operation: @escaping () async throws -> Void) {
        sending = true
        error = nil
        Task {
            do {
                try await operation()
                model.holdOpen = false
                model.focusedThreadID = nil
                model.onClose()
                model.show(Notice(tone: .success, symbol: "paperplane.fill", title: "Answer sent", subtitle: thread.title))
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}

// MARK: Shelf

struct ShelfTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Shelf").font(.system(size: 13, weight: .semibold))
                Text(shelf.items.isEmpty ? "" : "\(shelf.items.count) \(shelf.items.count == 1 ? "file" : "files")")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
                Spacer()
                if !shelf.items.isEmpty {
                    PillButton(title: "AirDrop all", tint: Palette.blue) {
                        _ = AirDrop.send(shelf.urls)
                        model.onClose()
                    }
                    PillButton(title: "Clear", tint: nil) { shelf.clear() }
                }
            }
            if shelf.items.isEmpty {
                EmptyLine(title: "Nothing on the shelf", detail: "Drag a file to the notch and drop it on Shelf to keep it here")
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(shelf.items) { item in
                            if let url = shelf.url(for: item) {
                                ShelfTile(url: url) { shelf.remove(item) }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ShelfTile: View {
    let url: URL
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 48, height: 48)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.secondary)
        }
        .frame(width: 76)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hovering ? 0.08 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                IconButton(symbol: "xmark", action: remove)
                    .scaleEffect(0.8)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("AirDrop") { _ = AirDrop.send([url]) }
            Divider()
            Button("Remove from Shelf", action: remove)
        }
    }
}

// MARK: Mirror

struct MirrorTab: View {
    @ObservedObject var camera: CameraMirror

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Color.white.opacity(0.06)
                if camera.denied {
                    Text("Allow camera access in System Settings → Privacy")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    CameraPreview(session: camera.session)
                }
            }
            .frame(width: 300, height: 136)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Mirror").font(.system(size: 13, weight: .semibold))
                Text("A quick look before a call. The camera stops when the island closes.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}

private extension T3Request {
    var summary: String {
        if let question = questions.first { return question.text }
        return prompt.isEmpty ? "Waiting for approval" : prompt
    }
}
