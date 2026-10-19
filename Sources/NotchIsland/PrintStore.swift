import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Prints dropped files on the printer where the Mac is right now. Uses CUPS network
/// discovery (`lpstat -e`), so nothing has to be set up and the printer follows the Mac
/// between places. `lp` makes a temporary queue on first use, without admin rights.
///
/// Prints are black and white on both sides unless `inColor` asks for colour on one side.
/// A printer that can't turn pages (an HP Smart Tank, say) gets the fronts first; the backs print once
/// the stack is back in the tray, turned over.
@MainActor
final class PrintStore: ObservableObject {
    struct Printer: Equatable {
        /// CUPS destination, e.g. `HP_Smart_Tank_Plus_550_series_FE61BE_`.
        let destination: String
        /// Short name for the drop zone, e.g. "HP Smart Tank".
        let name: String
        /// Prints both sides by itself (its CUPS queue has a Duplex option).
        let twoSided: Bool
    }

    enum Outcome {
        /// Queued with CUPS; `job` is the id `cancel` takes, `style` says "B&W, 2-sided" and the like.
        case queued(job: String, title: String, printer: String, style: String)
        /// Only the fronts are queued, on a printer that can't turn pages. `printBacks(_:)`
        /// prints `backs` once the stack is turned over.
        case frontsQueued(job: String, title: String, sheets: Int, backs: URL)
        /// Handed to the file's own app, which shows its print dialog.
        case inApp(title: String, app: String)
        /// The app couldn't be asked to print, so the file is open there instead.
        case opened(title: String, app: String)
        case failed(String)
    }

    @Published private(set) var printer: Printer?

    private var refreshing = false
    private let lastPrinterKey = "lastPrinter"

    /// Types CUPS prints directly. Everything else goes through its own app.
    private static let directTypes: [UTType] = [.pdf, .image, .plainText]

    /// Looks for network printers. Cheap (a few ms), so it runs whenever a drag starts.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        guard let output = await Shell.run(["/usr/bin/lpstat", "-e"], timeout: 3) else {
            if printer != nil { Log.write("print: lpstat -e failed, no printer") }
            printer = nil
            return
        }
        let destinations = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let last = UserDefaults.standard.string(forKey: lastPrinterKey)
        guard let destination = destinations.first(where: { $0 == last }) ?? destinations.first else {
            if printer != nil { Log.write("print: no network printer here") }
            printer = nil
            return
        }
        if printer?.destination == destination { return }
        let options = await Shell.run(["/usr/bin/lpoptions", "-p", destination], timeout: 3)
        let choices = await Shell.run(["/usr/bin/lpoptions", "-p", destination, "-l"], timeout: 3)
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let found = Printer(destination: destination,
                            name: Self.shortName(options.map { String(decoding: $0, as: UTF8.self) }, destination: destination),
                            twoSided: choices.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("Duplex/") })
        Log.write("print: using \(found.destination) (\(found.name), \(found.twoSided ? "two-sided" : "one-sided only"))")
        printer = found
    }

    /// Prints `urls`. `hold` queues the job held, so tests exercise CUPS without using paper.
    func print(_ urls: [URL], inColor: Bool = false, hold: Bool = false) async -> [Outcome] {
        let files = urls.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard !files.isEmpty else { return [.failed("Only files can be printed")] }
        let direct = files.filter(Self.printsDirectly)
        let others = files.filter { !Self.printsDirectly($0) }

        var outcomes: [Outcome] = []
        if !direct.isEmpty {
            outcomes.append(await queue(direct, inColor: inColor, hold: hold))
        }
        for (app, group) in Dictionary(grouping: others, by: { NSWorkspace.shared.urlForApplication(toOpen: $0) }) {
            outcomes.append(await printInApp(group, app: app))
        }
        return outcomes
    }

    func cancel(job: String) async -> Bool {
        let ok = await Shell.run(["/usr/bin/cancel", job], timeout: 10) != nil
        Log.write(ok ? "print: cancelled \(job)" : "print: cancelling \(job) failed")
        return ok
    }

    // MARK: CUPS

    private func queue(_ files: [URL], inColor: Bool, hold: Bool) async -> Outcome {
        await refresh()
        guard let printer else { return .failed("No printer found on this network") }
        let title = Self.title(for: files)
        if !inColor, !printer.twoSided,
           let split = await Task.detached(operation: { Self.splitForTurning(files) }).value {
            switch await submit([split.fronts], to: printer, title: "\(title) (fronts)",
                                options: Self.blackAndWhite, hold: hold) {
            case .job(let job):
                return .frontsQueued(job: job, title: title, sheets: split.sheets, backs: split.backs)
            case .error(let message):
                return .failed(message)
            }
        }
        let options: [String]
        let style: String
        switch (inColor, printer.twoSided) {
        case (true, _): (options, style) = (["sides=one-sided"], "colour")
        case (false, true): (options, style) = (Self.blackAndWhite + ["sides=two-sided-long-edge"], "B&W, 2-sided")
        case (false, false): (options, style) = (Self.blackAndWhite, "B&W")
        }
        switch await submit(files, to: printer, title: title, options: options, hold: hold) {
        case .job(let job): return .queued(job: job, title: title, printer: printer.name, style: style)
        case .error(let message): return .failed(message)
        }
    }

    /// Prints the backs from a `.frontsQueued` outcome, then deletes that file.
    func printBacks(_ backs: URL, title: String, hold: Bool = false) async -> Outcome {
        defer { try? FileManager.default.removeItem(at: backs) }
        await refresh()
        guard let printer else { return .failed("No printer found on this network") }
        switch await submit([backs], to: printer, title: "\(title) (backs)", options: Self.blackAndWhite, hold: hold) {
        case .job(let job): return .queued(job: job, title: "the backs of \(title)", printer: printer.name, style: "B&W")
        case .error(let message): return .failed(message)
        }
    }

    private static let blackAndWhite = ["print-color-mode=monochrome"]

    private enum Submission {
        case job(String)
        case error(String)
    }

    private func submit(_ files: [URL], to printer: Printer, title: String, options: [String], hold: Bool) async -> Submission {
        var arguments = ["/usr/bin/lp", "-d", printer.destination, "-t", title]
        for option in options { arguments += ["-o", option] }
        if hold { arguments += ["-H", "hold"] }
        arguments += files.map(\.path)
        let result = await Shell.capture(arguments, timeout: 30)
        guard result.status == 0,
              let job = result.output.range(of: #"request id is (\S+)"#, options: .regularExpression)
                .map({ String(result.output[$0].dropFirst("request id is ".count)) }) else {
            let message = result.error.isEmpty ? "lp exited with \(result.status)" : result.error
            Log.write("print: lp to \(printer.destination) failed: \(message)")
            return .error(message)
        }
        UserDefaults.standard.set(printer.destination, forKey: lastPrinterKey)
        Log.write("print: queued \(job) on \(printer.destination) [\(options.joined(separator: " "))]\(hold ? " (held)" : ""): \(title)")
        return .job(job)
    }

    // MARK: Turning pages by hand

    /// Splits PDFs into the fronts (odd pages) and backs (even pages) of their sheets, for
    /// a printer that can't turn pages. The stack goes back in turned over, blank side up
    /// and top edge first, which puts the first sheet first again, so the backs keep the
    /// same order. A document with an odd page count gets a blank last back, so every
    /// sheet feeds through again and the stack comes out in order.
    ///
    /// Nil when there is nothing to put on a back (every document has one page), or a file
    /// isn't an unlocked PDF; those print one-sided.
    nonisolated private static func splitForTurning(_ files: [URL]) -> (fronts: URL, backs: URL, sheets: Int)? {
        guard files.allSatisfy({ contentType(of: $0)?.conforms(to: .pdf) == true }) else { return nil }
        let documents = files.compactMap(PDFDocument.init(url:))
        guard documents.count == files.count, !documents.contains(where: \.isLocked),
              documents.contains(where: { $0.pageCount > 1 }) else { return nil }
        let fronts = PDFDocument()
        let backs = PDFDocument()
        for document in documents {
            for index in stride(from: 0, to: document.pageCount, by: 2) {
                guard let front = document.page(at: index)?.copy() as? PDFPage else { return nil }
                let back = index + 1 < document.pageCount ? document.page(at: index + 1)?.copy() as? PDFPage : nil
                fronts.insert(front, at: fronts.pageCount)
                backs.insert(back ?? blankPage(like: front), at: backs.pageCount)
            }
        }
        // One turn waits at a time, so older halves can go.
        let folder = FileManager.default.temporaryDirectory.appending(path: "NotchIsland-print")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frontsURL = folder.appending(path: "fronts.pdf")
        let backsURL = folder.appending(path: "backs.pdf")
        guard fronts.write(to: frontsURL), backs.write(to: backsURL) else {
            Log.write("print: couldn't write the fronts and backs to \(folder.path)")
            return nil
        }
        return (frontsURL, backsURL, fronts.pageCount)
    }

    nonisolated private static func blankPage(like page: PDFPage) -> PDFPage {
        let blank = PDFPage()
        blank.setBounds(page.bounds(for: .mediaBox), for: .mediaBox)
        blank.rotation = page.rotation
        return blank
    }

    // MARK: Other documents

    /// Asks the document's app to print it with its print dialog. If that app can't be
    /// asked, the file opens there instead so ⌘P is one step away.
    private func printInApp(_ files: [URL], app: URL?) async -> Outcome {
        let title = Self.title(for: files)
        guard let app, let bundleID = Bundle(url: app)?.bundleIdentifier else {
            return .failed("No app can open \(title)")
        }
        let appName = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let printed: Bool = await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
                guard error == nil else {
                    Log.write("print: launching \(bundleID) failed: \(String(describing: error))")
                    continuation.resume(returning: false)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.sendPrintEvent(files, to: bundleID))
                }
            }
        }
        if printed { return .inApp(title: title, app: appName) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.open(files, withApplicationAt: app, configuration: configuration)
        return .opened(title: title, app: appName)
    }

    /// Sends the standard "print documents" Apple Event with the print dialog on.
    /// Runs off the main thread: the Automation prompt can block it.
    nonisolated private static func sendPrintEvent(_ files: [URL], to bundleID: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let permission = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, AEEventClass(kCoreEventClass), AEEventID(kAEPrintDocuments), true
        )
        guard permission == noErr else {
            Log.write("print: Automation access to \(bundleID) returned \(permission)")
            return false
        }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEPrintDocuments),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        let list = NSAppleEventDescriptor.list()
        for (index, file) in files.enumerated() {
            list.insert(NSAppleEventDescriptor(fileURL: file), at: index + 1)
        }
        event.setParam(list, forKeyword: keyDirectObject)
        // 'pdlg', the standard suite's "print dialog" flag.
        event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: 0x70646C67)
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 10)
            Log.write("print: asked \(bundleID) to print \(files.count) file(s)")
            return true
        } catch {
            Log.write("print: print event to \(bundleID) failed: \(error)")
            return false
        }
    }

    // MARK: Helpers

    private static func printsDirectly(_ url: URL) -> Bool {
        guard let type = contentType(of: url) else { return false }
        return directTypes.contains { type.conforms(to: $0) }
    }

    nonisolated private static func contentType(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
    }

    private static func title(for files: [URL]) -> String {
        files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
    }

    /// "HP Smart Tank Plus 550 series [FE61BE]" → "HP Smart Tank": no model numbers,
    /// no "series", at most three words.
    private static func shortName(_ options: String?, destination: String) -> String {
        let raw = options.flatMap { text in
            ["printer-make-and-model", "printer-info"].lazy.compactMap { key in
                text.range(of: "\(key)='([^']*)'", options: .regularExpression).map {
                    String(text[$0].dropFirst(key.count + 2).dropLast())
                }
            }.first
        } ?? destination.replacingOccurrences(of: "_", with: " ")
        let words = raw
            .replacingOccurrences(of: #"\[.*?\]"#, with: "", options: .regularExpression)
            .split(separator: " ")
            .filter { !$0.contains(where: \.isNumber) && $0.lowercased() != "series" }
        return words.isEmpty ? destination : words.prefix(3).joined(separator: " ")
    }
}

extension Shell {
    /// Like `run`, but keeps the exit status and stderr for error messages.
    static func capture(_ arguments: [String], timeout: TimeInterval = 30) async -> (status: Int32, output: String, error: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: arguments[0])
                process.arguments = Array(arguments.dropFirst())
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, "", error.localizedDescription))
                    return
                }
                let killer = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let stdout = output.fileHandleForReading.readDataToEndOfFile()
                let stderr = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: (
                    process.terminationStatus,
                    String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
    }
}
