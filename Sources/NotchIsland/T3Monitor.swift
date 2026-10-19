import AppKit

/// A question or approval an agent is waiting on.
struct T3Request: Equatable {
    struct Option: Equatable {
        let label: String
        let value: String
        let detail: String
    }

    struct Question: Equatable {
        let id: String
        let header: String
        let text: String
        let options: [Option]
        let multiSelect: Bool
        let allowsCustom: Bool
    }

    struct Choice: Equatable {
        let decision: String
        let label: String
    }

    let id: String
    let kind: String
    let questions: [Question]
    /// Approval requests carry a prompt and decisions instead of questions.
    let prompt: String
    let choices: [Choice]

    var isApproval: Bool { questions.isEmpty && !choices.isEmpty }
}

struct T3Thread: Identifiable, Equatable {
    enum State: String {
        case needsInput
        case working
        case queued
        case completed
        case failed

        var isActive: Bool {
            switch self {
            case .needsInput, .working, .queued: return true
            case .completed, .failed: return false
            }
        }

        var rank: Int {
            switch self {
            case .needsInput: return 0
            case .working: return 1
            case .queued: return 2
            case .failed: return 3
            case .completed: return 4
            }
        }
    }

    let host: String
    let threadID: String
    let title: String
    let project: String
    let state: State
    /// When the current state began: run start, request time, or finish time.
    let since: Date?
    let startedAt: Date?
    let request: T3Request?

    var id: String { "\(host)/\(threadID)" }
    var place: String { project.isEmpty ? host : "\(host) · \(project)" }
}

enum T3Event {
    case finished(T3Thread)
    case failed(T3Thread)
    case needsInput(T3Thread)
}

/// Watches T3 Code servers on this Mac and on the SSH hosts listed in the `t3RemoteHosts` default.
/// Each host runs the same small read-only SQLite poller and streams JSON lines back.
@MainActor
final class T3Monitor: ObservableObject {
    @Published private(set) var threads: [T3Thread] = []
    @Published private(set) var offlineHosts: [String] = []
    @Published private(set) var flash: Bool?
    var onEvent: (T3Event) -> Void = { _ in }

    private var sources: [T3Source] = []
    private var threadsByHost: [String: [T3Thread]] = [:]
    private var flashDismissal: DispatchWorkItem?

    init() {
        let remoteHosts = UserDefaults.standard.stringArray(forKey: "t3RemoteHosts") ?? []
        sources.append(T3Source(host: "Mac", remote: nil))
        for (index, host) in remoteHosts.enumerated() {
            sources.append(T3Source(host: host, remote: .init(sshHost: host, tunnelPort: 47731 + index)))
        }
        for source in sources {
            source.onSnapshot = { [weak self] host, threads in self?.apply(threads, from: host) }
            source.onReachability = { [weak self] host, online in self?.setReachable(host, online) }
        }
    }

    func start() { sources.forEach { $0.start() } }
    func stop() { sources.forEach { $0.stop() } }

    var needsInputCount: Int { threads.filter { $0.state == .needsInput }.count }
    var workingCount: Int { threads.filter { $0.state == .working || $0.state == .queued }.count }

    func thread(withID id: String) -> T3Thread? {
        threads.first { $0.id == id }
    }

    // MARK: Actions

    /// Opens the thread itself in T3 Code; falls back to bringing the app forward.
    func open(_ thread: T3Thread) {
        guard let source = source(for: thread.host), let environment = source.environmentID,
              let url = URL(string: "t3code://threads/\(environment)/\(thread.threadID)") else {
            T3App.activate()
            return
        }
        T3App.open(url)
    }

    func answer(_ thread: T3Thread, answers: [String: String]) async throws {
        guard let request = thread.request else { return }
        try await withClient(for: thread.host) { client in
            try await client.respond(threadID: thread.threadID, requestID: request.id, answers: answers)
        }
    }

    func decide(_ thread: T3Thread, decision: String) async throws {
        guard let request = thread.request else { return }
        try await withClient(for: thread.host) { client in
            try await client.decide(threadID: thread.threadID, requestID: request.id, decision: decision)
        }
    }

    /// Uses the stored token for the host, minting one the first time an answer is sent.
    private func withClient(for host: String, _ body: (T3Client) async throws -> Void) async throws {
        guard let source = source(for: host), let baseURL = source.baseURL else {
            throw T3MonitorError.hostUnavailable(host)
        }
        if let token = T3TokenStore.token(for: host) {
            do {
                try await body(T3Client(baseURL: baseURL, token: token))
                return
            } catch let error as T3ClientError where error.isUnauthorized {
                // Expired or revoked: mint a fresh token below.
            }
        }
        let token = try await T3Client.issueToken(using: source.issueTokenCommand)
        T3TokenStore.save(token, for: host)
        try await body(T3Client(baseURL: baseURL, token: token))
    }

    private func source(for host: String) -> T3Source? {
        sources.first { $0.host == host }
    }

    // MARK: Snapshots

    private func apply(_ threads: [T3Thread], from host: String) {
        let previous = threadsByHost[host]
        threadsByHost[host] = threads
        if let previous {
            announceTransitions(from: previous, to: threads)
        }
        rebuild()
    }

    private func rebuild() {
        threads = threadsByHost.values.flatMap { $0 }.sorted { left, right in
            if left.state.rank != right.state.rank { return left.state.rank < right.state.rank }
            return (left.since ?? .distantPast) > (right.since ?? .distantPast)
        }
    }

    private func announceTransitions(from previous: [T3Thread], to current: [T3Thread]) {
        let before = Dictionary(previous.map { ($0.threadID, $0.state) }, uniquingKeysWith: { first, _ in first })
        for thread in current {
            let old = before[thread.threadID]
            switch thread.state {
            case .completed where old?.isActive == true:
                showFlash(success: true)
                onEvent(.finished(thread))
            case .failed where old?.isActive == true:
                showFlash(success: false)
                onEvent(.failed(thread))
            case .needsInput where old != .needsInput:
                onEvent(.needsInput(thread))
            case .needsInput, .working, .queued, .completed, .failed:
                break
            }
        }
    }

    private func showFlash(success: Bool) {
        flash = success
        flashDismissal?.cancel()
        let dismissal = DispatchWorkItem { [weak self] in self?.flash = nil }
        flashDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: dismissal)
    }

    private func setReachable(_ host: String, _ online: Bool) {
        if online {
            offlineHosts.removeAll { $0 == host }
        } else if !offlineHosts.contains(host) {
            offlineHosts.append(host)
            threadsByHost[host] = nil
            rebuild()
        }
    }
}

enum T3MonitorError: LocalizedError {
    case hostUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .hostUnavailable(let host): return "Can't reach T3 on \(host) right now."
        }
    }
}

enum T3App {
    static let bundleID = "com.t3tools.t3code"
    /// Alpha and Nightly share a bundle ID and URL scheme, so links go to Nightly explicitly.
    static let nightlyURL = URL(fileURLWithPath: "/Applications/T3 Code (Nightly).app")

    @MainActor
    static func activate() {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            running.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @MainActor
    static func open(_ link: URL) {
        guard FileManager.default.fileExists(atPath: nightlyURL.path) else {
            NSWorkspace.shared.open(link)
            return
        }
        NSWorkspace.shared.open([link], withApplicationAt: nightlyURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Runs the poller script locally or over SSH and restarts it when it dies.
/// The SSH connection also forwards the remote T3 server so answers can be sent.
@MainActor
final class T3Source {
    struct Remote {
        let sshHost: String
        let tunnelPort: Int
    }

    let host: String
    let remote: Remote?
    var onSnapshot: (String, [T3Thread]) -> Void = { _, _ in }
    var onReachability: (String, Bool) -> Void = { _, _ in }
    private(set) var environmentID: String?
    private var serverPort = 3773

    private var process: Process?
    private var buffer = Data()
    private var retryDelay: TimeInterval = 2
    private var lastLine = Date()
    private var watchdog: Timer?
    private var stopped = false

    init(host: String, remote: Remote?) {
        self.host = host
        self.remote = remote
    }

    var baseURL: URL? {
        let port = remote?.tunnelPort ?? serverPort
        return URL(string: "http://127.0.0.1:\(port)")
    }

    var issueTokenCommand: [String] {
        let arguments = "auth session issue --scope orchestration:read --scope orchestration:operate --ttl 90d --label NotchIsland --token-only"
        if let remote {
            // Prefer the CLI that matches the running server; the ~/.t3/bin wrapper can lag behind it.
            let script = """
            v=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.t3/userdata/server-runtime.json"))).get("serverVersion",""))' 2>/dev/null); \
            cli=~/.t3/runtime/versions/$v/t3; [ -x "$cli" ] || cli=~/.t3/bin/t3; T3CODE_HOME=~/.t3 "$cli" \(arguments)
            """
            return ["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", remote.sshHost, script]
        }
        let cli = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/bin/t3").path
        return [cli] + arguments.split(separator: " ").map(String.init)
    }

    private var command: [String] {
        guard let remote else { return ["/usr/bin/python3", "-I", "-u", "-"] }
        return [
            "/usr/bin/ssh", "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=no",
            "-L", "\(remote.tunnelPort):127.0.0.1:\(serverPort)",
            remote.sshHost, "python3 -I -u -",
        ]
    }

    func start() {
        stopped = false
        launch()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateIfStale() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    func stop() {
        stopped = true
        watchdog?.invalidate()
        process?.terminate()
    }

    private func launch() {
        guard !stopped else { return }
        let process = Process()
        let command = command
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.didExit(finished) }
            }
        }
        buffer.removeAll()
        lastLine = Date()
        do {
            try process.run()
            self.process = process
            // Writing to a poller that already died must fail quietly, not kill the app.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try input.fileHandleForWriting.write(contentsOf: Data(T3Script.source.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            Log.write("T3 poller for \(host) failed to start: \(error)")
            if self.process == nil { scheduleRelaunch() }
        }
    }

    private func didExit(_ finished: Process) {
        guard finished === process else { return }
        process = nil
        onReachability(host, false)
        scheduleRelaunch()
    }

    private func scheduleRelaunch() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launch() }
    }

    private func terminateIfStale() {
        // The poller prints a heartbeat every 30 s; silence means a hung connection.
        guard let process, Date().timeIntervalSince(lastLine) > 75 else { return }
        process.terminate()
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            decode(line)
        }
    }

    private func decode(_ line: Data) {
        guard let payload = try? JSONDecoder().decode(T3Payload.self, from: line) else { return }
        lastLine = Date()
        guard let items = payload.threads else {
            Log.write("T3 poller on \(host) reported: \(payload.error ?? "unknown error")")
            onReachability(host, false)
            return
        }
        retryDelay = 2
        environmentID = payload.environment ?? environmentID
        if let port = payload.port, port != serverPort {
            serverPort = port
            // The tunnel was opened for the old port; reconnect to forward the new one.
            if remote != nil { process?.terminate() }
        }
        onReachability(host, true)
        onSnapshot(host, items.compactMap { $0.thread(host: host) })
    }
}

private struct T3Payload: Decodable {
    struct Item: Decodable {
        struct Request: Decodable {
            struct Question: Decodable {
                struct Option: Decodable {
                    let label: String
                    let value: String
                    let description: String
                }

                let id: String
                let header: String
                let question: String
                let options: [Option]
                let multiSelect: Bool
                let allowCustom: Bool
            }

            struct Choice: Decodable {
                let decision: String
                let label: String
            }

            let id: String
            let kind: String
            let questions: [Question]
            let prompt: String
            let choices: [Choice]
        }

        let id: String
        let title: String
        let project: String
        let state: String
        let at: Double?
        let started: Double?
        let request: Request?

        func thread(host: String) -> T3Thread? {
            guard let state = T3Thread.State(rawValue: state) else { return nil }
            return T3Thread(
                host: host,
                threadID: id,
                title: title,
                project: project,
                state: state,
                since: at.map { Date(timeIntervalSince1970: $0) },
                startedAt: started.map { Date(timeIntervalSince1970: $0) },
                request: request.map { request in
                    T3Request(
                        id: request.id,
                        kind: request.kind,
                        questions: request.questions.map { question in
                            T3Request.Question(
                                id: question.id,
                                header: question.header,
                                text: question.question,
                                options: question.options.map { .init(label: $0.label, value: $0.value, detail: $0.description) },
                                multiSelect: question.multiSelect,
                                allowsCustom: question.allowCustom
                            )
                        },
                        prompt: request.prompt,
                        choices: request.choices.map { .init(decision: $0.decision, label: $0.label) }
                    )
                }
            )
        }
    }

    let threads: [Item]?
    let environment: String?
    let port: Int?
    let error: String?
}

/// Read-only poller. Runs on each host with the system python3 and only prints when something changes.
enum T3Script {
    static let source = #"""
import json
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path

USERDATA = Path.home() / ".t3" / "userdata"
DB = USERDATA / "statev2.sqlite"
ACTIVE = ("queued", "preparing", "starting", "running", "waiting")
RECENT_SECONDS = 30 * 60
POLL_SECONDS = 2
HEARTBEAT_SECONDS = 30


def epoch(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def server_info():
    environment, port = None, None
    try:
        environment = (USERDATA / "environment-id").read_text().strip() or None
    except OSError:
        pass
    try:
        port = json.loads((USERDATA / "server-runtime.json").read_text()).get("port")
    except (OSError, ValueError):
        pass
    return environment, port


def request_details(db, request_id, node_id, kind):
    details = {"id": request_id, "kind": kind, "questions": [], "prompt": "", "choices": []}
    rows = db.execute(
        "select type, payload_json from orchestration_v2_projection_turn_items"
        " where node_id = ? and type in ('user_input_request', 'approval_request')",
        (node_id,),
    )
    for item_type, payload in rows:
        item = json.loads(payload)
        if item.get("requestId") != request_id:
            continue
        if item_type == "user_input_request":
            for question in item.get("questions") or []:
                details["questions"].append({
                    "id": str(question.get("id", "")),
                    "header": question.get("header") or "",
                    "question": question.get("question") or "",
                    "options": [
                        {
                            "label": option.get("label") or "",
                            "value": option.get("value") or option.get("label") or "",
                            "description": option.get("description") or "",
                        }
                        for option in question.get("options") or []
                    ],
                    "multiSelect": bool(question.get("multiSelect")),
                    "allowCustom": question.get("allowCustomAnswer") is not False,
                })
        else:
            details["prompt"] = item.get("prompt") or item.get("appName") or ""
            details["choices"] = [
                {"decision": option["decision"], "label": option.get("label") or option["decision"]}
                for option in item.get("options") or []
                if option.get("decision")
            ]
    return details


def snapshot(db):
    since = datetime.fromtimestamp(time.time() - RECENT_SECONDS, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    latest = {}
    rows = db.execute(
        "select thread_id, ordinal, status, requested_at, completed_at"
        " from orchestration_v2_projection_runs"
        " where status in (?, ?, ?, ?, ?) or completed_at >= ?",
        ACTIVE + (since,),
    )
    for thread_id, ordinal, status, requested_at, completed_at in rows:
        # A steered message adds a newer run that gets cancelled while the original keeps
        # working, so an active run always wins over newer finished ones.
        current = latest.get(thread_id)
        active, current_active = status in ACTIVE, current is not None and current[1] in ACTIVE
        if current is None or (active and not current_active) or (active == current_active and ordinal > current[0]):
            latest[thread_id] = (ordinal, status, requested_at, completed_at)
    pending = {}
    rows = db.execute(
        "select thread_id, runtime_request_id, node_id, kind, created_at"
        " from orchestration_v2_projection_runtime_requests where status = 'pending'"
        " order by created_at"
    )
    for thread_id, request_id, node_id, kind, created_at in rows:
        pending.setdefault(thread_id, (request_id, node_id, kind, created_at))
    ids = sorted(set(latest) | set(pending))
    if not ids:
        return []
    threads = db.execute(
        "select t.thread_id, t.title, coalesce(p.title, '')"
        " from orchestration_v2_projection_threads t"
        " left join projection_projects p on p.project_id = t.project_id"
        " where t.deleted_at is null and t.archived_at is null"
        " and t.thread_id in (" + ",".join("?" for _ in ids) + ")",
        ids,
    ).fetchall()
    result = []
    for thread_id, title, project in threads:
        _, status, requested_at, completed_at = latest.get(thread_id, (0, None, None, None))
        request = None
        if thread_id in pending:
            request_id, node_id, kind, created_at = pending[thread_id]
            state, at = "needsInput", created_at
            request = request_details(db, request_id, node_id, kind)
        elif status == "queued":
            state, at = "queued", requested_at
        elif status in ACTIVE:
            state, at = "working", requested_at
        elif status in ("completed", "failed"):
            state, at = status, completed_at
        else:
            continue
        if project == "No project":
            project = ""
        result.append({
            "id": thread_id,
            "title": title,
            "project": project,
            "state": state,
            "at": epoch(at),
            "started": epoch(requested_at),
            "request": request,
        })
    return result


def main():
    db = None
    last_text = None
    last_sent = 0.0
    while True:
        environment, port = server_info()
        try:
            if db is None:
                db = sqlite3.connect(DB.as_uri() + "?mode=ro", uri=True, timeout=2)
            payload = {"threads": snapshot(db), "environment": environment, "port": port}
        except Exception as error:
            if db is not None:
                db.close()
            db = None
            payload = {"error": str(error)}
        text = json.dumps(payload, sort_keys=True)
        now = time.monotonic()
        if text != last_text or now - last_sent >= HEARTBEAT_SECONDS:
            print(text, flush=True)
            last_text, last_sent = text, now
        time.sleep(POLL_SECONDS)


main()
"""#
}
