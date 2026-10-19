import AppKit

/// Your open GitHub pull requests with their check status, and recent Railway deploys.
/// Uses the `gh` and `railway` CLIs, so it rides on their existing logins.
@MainActor
final class DevMonitor: ObservableObject {
    struct PullRequest: Identifiable, Equatable {
        enum Checks: Equatable {
            case passing
            case failing
            case pending
            case none
        }

        let url: URL
        let number: Int
        let title: String
        let repo: String
        let checks: Checks
        var id: String { url.absoluteString }
    }

    struct Deploy: Identifiable, Equatable {
        enum Status: Equatable {
            case building
            case live
            case failed
            case idle
        }

        let id: String
        let project: String
        let service: String
        let status: Status
        let createdAt: Date
        let url: URL?
    }

    enum Event {
        case checksFailed(PullRequest)
        case checksPassed(PullRequest)
        case deployFailed(Deploy)
        case deployLive(Deploy)
    }

    @Published private(set) var pulls: [PullRequest] = []
    /// Only deploys that are running now or changed in the last three hours.
    @Published private(set) var deploys: [Deploy] = []
    var onEvent: (Event) -> Void = { _ in }

    private var timer: Timer?
    private var loadedPulls = false
    private var loadedDeploys = false

    private static let gh = firstExisting(["/opt/homebrew/bin/gh", "/usr/local/bin/gh"])
    private static let railway = firstExisting([
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".railway/bin/railway").path,
        "/opt/homebrew/bin/railway",
    ])

    func start() {
        refresh()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        Task {
            async let pulls = Self.fetchPulls()
            async let deploys = Self.fetchDeploys()
            if let pulls = await pulls { apply(pulls) }
            if let deploys = await deploys { apply(deploys) }
        }
    }

    var failingPulls: [PullRequest] { pulls.filter { $0.checks == .failing } }
    var buildingDeploys: [Deploy] { deploys.filter { $0.status == .building } }

    private func apply(_ pulls: [PullRequest]) {
        if loadedPulls {
            let before = Dictionary(self.pulls.map { ($0.id, $0.checks) }, uniquingKeysWith: { first, _ in first })
            for pull in pulls where before[pull.id] == .pending {
                switch pull.checks {
                case .failing: onEvent(.checksFailed(pull))
                case .passing: onEvent(.checksPassed(pull))
                case .pending, .none: break
                }
            }
        }
        loadedPulls = true
        self.pulls = pulls
    }

    private func apply(_ deploys: [Deploy]) {
        if loadedDeploys {
            let before = Dictionary(self.deploys.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
            for deploy in deploys where before[deploy.id] == .building {
                switch deploy.status {
                case .failed: onEvent(.deployFailed(deploy))
                case .live: onEvent(.deployLive(deploy))
                case .building, .idle: break
                }
            }
        }
        loadedDeploys = true
        self.deploys = deploys
    }

    // MARK: Fetching

    private static func fetchPulls() async -> [PullRequest]? {
        guard let gh else { return nil }
        let query = """
        query { viewer { pullRequests(first: 15, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes {
          number title url repository { nameWithOwner }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        } } } }
        """
        guard let data = await Shell.run([gh, "api", "graphql", "-f", "query=\(query)"]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = root.value(at: ["data", "viewer", "pullRequests", "nodes"]) as? [[String: Any]] else { return nil }
        return nodes.compactMap { node in
            guard let number = node["number"] as? Int,
                  let title = node["title"] as? String,
                  let url = (node["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            let commits = node.value(at: ["commits", "nodes"]) as? [[String: Any]]
            let state = commits?.last?.value(at: ["commit", "statusCheckRollup", "state"]) as? String
            let checks: PullRequest.Checks
            switch state {
            case "SUCCESS": checks = .passing
            case "FAILURE", "ERROR": checks = .failing
            case "PENDING", "EXPECTED": checks = .pending
            default: checks = .none
            }
            return PullRequest(
                url: url,
                number: number,
                title: title,
                repo: node.value(at: ["repository", "nameWithOwner"]) as? String ?? "",
                checks: checks
            )
        }
    }

    private static func fetchDeploys() async -> [Deploy]? {
        guard let railway else { return nil }
        let query = """
        query { me { workspaces { projects(first: 50) { edges { node { id name services { edges { node {
          id name deployments(first: 1) { edges { node { id status createdAt } } }
        } } } } } } } } }
        """
        guard let data = await Shell.run([railway, "api", query]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspaces = root.value(at: ["data", "me", "workspaces"]) as? [[String: Any]] else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let cutoff = Date().addingTimeInterval(-3 * 3600)
        var result: [Deploy] = []
        for workspace in workspaces {
            for project in workspace.value(at: ["projects", "edges"]) as? [[String: Any]] ?? [] {
                guard let projectNode = project["node"] as? [String: Any] else { continue }
                let projectID = projectNode["id"] as? String ?? ""
                for service in projectNode.value(at: ["services", "edges"]) as? [[String: Any]] ?? [] {
                    guard let serviceNode = service["node"] as? [String: Any],
                          let deployment = (serviceNode.value(at: ["deployments", "edges"]) as? [[String: Any]])?.first?["node"] as? [String: Any],
                          let status = deployment["status"] as? String,
                          let createdAt = (deployment["createdAt"] as? String).flatMap(formatter.date(from:)) else { continue }
                    let mapped: Deploy.Status
                    switch status {
                    case "BUILDING", "DEPLOYING", "INITIALIZING", "QUEUED", "WAITING": mapped = .building
                    case "SUCCESS": mapped = .live
                    case "FAILED", "CRASHED": mapped = .failed
                    default: mapped = .idle
                    }
                    guard mapped == .building || createdAt > cutoff else { continue }
                    let serviceID = serviceNode["id"] as? String ?? ""
                    result.append(Deploy(
                        id: "\(projectID)/\(serviceID)",
                        project: projectNode["name"] as? String ?? "",
                        service: serviceNode["name"] as? String ?? "",
                        status: mapped,
                        createdAt: createdAt,
                        url: URL(string: "https://railway.com/project/\(projectID)/service/\(serviceID)")
                    ))
                }
            }
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func value(at path: [String]) -> Any? {
        var current: Any? = self
        for key in path {
            current = (current as? [String: Any])?[key]
        }
        return current
    }
}

enum Shell {
    /// Runs a command off the main thread and returns stdout, or nil on a non-zero exit.
    static func run(_ arguments: [String], timeout: TimeInterval = 30) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: arguments[0])
                process.arguments = Array(arguments.dropFirst())
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let killer = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
