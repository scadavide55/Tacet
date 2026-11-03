import Observation
import AppKit
import WebKit

@Observable
final class DownloadItem: NSObject, Identifiable {
    enum State: Equatable { case active, paused, finished, failed(String), cancelled }

    let id: UUID
    /// Replaced when a stopped download is resumed; nil for downloads listed from an earlier launch.
    @ObservationIgnored fileprivate(set) var download: WKDownload?
    let source: URL?
    /// What WebKit needs to continue a download that was paused, failed or was cancelled.
    fileprivate(set) var resumeData: Data?
    var filename = L("Download")
    var destination: URL?
    var fraction = 0.0
    var received: Int64 = 0
    var total: Int64 = 0
    var state = State.active
    let started: Date
    var finished: Date?
    /// Bytes a second, over the last few seconds.
    fileprivate(set) var speed = 0.0
    /// Downloads from private windows aren't remembered.
    let isPrivate: Bool
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var lastUpdate = Date.distantPast
    @ObservationIgnored private var samples: [(time: Date, bytes: Int64)] = []

    init(_ download: WKDownload) {
        id = UUID()
        self.download = download
        source = download.originalRequest?.url
        started = Date()
        isPrivate = download.webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? false
        super.init()
        observe(download)
    }

    /// A download listed from an earlier launch.
    init(saved: DownloadManager.Saved) {
        id = saved.id
        source = saved.source
        started = saved.started
        finished = saved.finished
        isPrivate = false
        super.init()
        filename = saved.filename
        destination = saved.destination
        received = saved.received
        total = saved.total
        resumeData = saved.resumeData
        fraction = total > 0 ? Double(received) / Double(total) : 0
        switch saved.state {
        case "finished": state = .finished; fraction = 1
        case "cancelled": state = .cancelled; resumeData = nil
        case "paused" where saved.resumeData != nil: state = .paused
        // Tacet quit while it was downloading: WebKit can't go on from there.
        case "active", "paused": state = .failed(L("Stopped when Tacet quit"))
        default: state = .failed(saved.reason ?? L("Failed"))
        }
    }

    var canResume: Bool { resumeData != nil && state != .active && state != .finished }
    var canRetry: Bool { source.map { ["http", "https"].contains($0.scheme ?? "") } ?? false }

    fileprivate func observe(_ download: WKDownload) {
        samples = []
        speed = 0
        observation = download.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let fraction = p.fractionCompleted
            let done = p.completedUnitCount
            let total = p.totalUnitCount
            DispatchQueue.main.async {
                guard let self else { return }
                // Progress arrives for every chunk; ten redraws a second are plenty.
                let now = Date()
                guard fraction >= 1 || now.timeIntervalSince(self.lastUpdate) >= 0.1 else { return }
                self.lastUpdate = now
                self.fraction = fraction
                self.received = done
                self.total = total
            }
        }
    }

    /// Called every second while the download runs, to keep the speed current even when nothing arrives.
    fileprivate func sample() {
        let now = Date()
        samples.append((now, received))
        samples.removeAll { now.timeIntervalSince($0.time) > 4 }
        guard let first = samples.first, let last = samples.last, last.time.timeIntervalSince(first.time) >= 0.9 else { return }
        speed = max(0, Double(last.bytes - first.bytes) / last.time.timeIntervalSince(first.time))
    }

    fileprivate func stopSampling() {
        samples = []
        speed = 0
    }

    /// Seconds left at the current speed, when the size is known.
    var timeLeft: TimeInterval? {
        guard state == .active, total > 0, speed > 1 else { return nil }
        return Double(total - received) / speed
    }

    var statusText: String {
        let f = Self.bytes
        let size = total > 0 ? String(format: L("%@ of %@"), f.string(fromByteCount: received), f.string(fromByteCount: total))
            : f.string(fromByteCount: received)
        switch state {
        case .active:
            if destination == nil { return L("Waiting for a place to save it…") }
            guard speed > 0 else { return size }
            var parts = [size, Self.speedText(speed)]
            if let left = timeLeft { parts.append(Self.timeText(left)) }
            return parts.joined(separator: " · ")
        case .paused: return L("Paused") + " · " + size
        case .finished:
            if let destination, !FileManager.default.fileExists(atPath: destination.path) { return L("Moved or deleted") }
            return f.string(fromByteCount: max(total, received)) + (source?.host.map { " · " + $0 } ?? "")
        case .failed(let reason): return reason
        case .cancelled: return L("Cancelled")
        }
    }

    static func speedText(_ bytesPerSecond: Double) -> String {
        String(format: L("%@/s"), ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file))
    }

    static func timeText(_ seconds: TimeInterval) -> String {
        guard seconds >= 5 else { return L("almost done") }
        let f = seconds < 3600 ? minutes : hours
        return String(format: L("%@ left"), f.string(from: seconds) ?? "")
    }

    /// Made once: rows showing a download in progress redraw ten times a second.
    private static let bytes = ByteCountFormatter()
    private static let minutes = durationFormatter(units: 1)
    private static let hours = durationFormatter(units: 2)

    private static func durationFormatter(units: Int) -> DateComponentsFormatter {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = units
        f.allowedUnits = [.hour, .minute, .second]
        return f
    }

    /// The file's icon, asked of macOS once per file rather than each time the row redraws (ten times a second while
    /// it downloads).
    var icon: NSImage {
        let path = destination.map(\.path) ?? ""
        let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path)
        let done = state == .finished
        if let c = iconCache, c.path == path, c.exists == exists, c.done == done { return c.image }
        let image = exists ? NSWorkspace.shared.icon(forFile: path) : NSWorkspace.shared.icon(for: .data)
        iconCache = (path, exists, done, image)
        return image
    }
    @ObservationIgnored private var iconCache: (path: String, exists: Bool, done: Bool, image: NSImage)?
}

@Observable
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()
    private(set) var items: [DownloadItem] = []
    var unseen = false
    @ObservationIgnored private let file = StoredFile<[Saved]>("downloads.plist", format: .binaryPlist)
    @ObservationIgnored private var timer: Timer?

    /// One remembered download.
    struct Saved: Codable {
        var id: UUID
        var source: URL?
        var filename: String
        var destination: URL?
        var received: Int64
        var total: Int64
        var state: String
        var reason: String?
        var started: Date
        var finished: Date?
        var resumeData: Data?
    }

    /// How many downloads the list keeps.
    static let limit = 200

    override init() {
        super.init()
        items = (file.load() ?? []).map(DownloadItem.init(saved:))
        removeOld()
    }

    /// Drops finished, failed and cancelled downloads older than Settings › General › Downloads allows. The files stay.
    func removeOld() {
        let days = Settings.shared.downloadsKeepDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let before = items.count
        items.removeAll { $0.state != .active && $0.state != .paused && ($0.finished ?? $0.started) < cutoff }
        if items.count != before { persist() }
    }

    /// When the last private window closes, its downloads leave the list (the files stay), like the rest of what it did.
    func forgetPrivate() {
        items.removeAll { $0.isPrivate && $0.state != .active }
        updateBadge()
    }

    /// Clearing history clears the list too, as in Safari: everything since `date`, or all of it. The files stay.
    func clearList(since date: Date?) {
        items.removeAll { $0.state != .active && $0.state != .paused && (date == nil || $0.started >= date!) }
        persist()
    }

    var active: [DownloadItem] { items.filter { $0.state == .active } }
    var overallFraction: Double {
        let a = active
        return a.isEmpty ? 1 : a.map(\.fraction).reduce(0, +) / Double(a.count)
    }
    var totalSpeed: Double { active.map(\.speed).reduce(0, +) }

    func track(_ download: WKDownload) {
        removeOld()
        download.delegate = self
        items.insert(DownloadItem(download), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        unseen = true
        startTimer()
        persist()
    }

    private func item(for download: WKDownload) -> DownloadItem? { items.first { $0.download === download } }

    // MARK: Speed

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let running = active
        running.forEach { $0.sample() }
        updateBadge()
        if running.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: Saving the list

    /// How many files are downloading, on Tacet's Dock icon.
    private func updateBadge() {
        let n = active.count
        let label = n > 0 ? String(n) : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    private func persist() {
        updateBadge()
        let saved = items.filter { !$0.isPrivate }.map { item -> Saved in
            let state: String
            var reason: String?
            switch item.state {
            case .active: state = "active"
            case .paused: state = "paused"
            case .finished: state = "finished"
            case .cancelled: state = "cancelled"
            case .failed(let r): state = "failed"; reason = r
            }
            return Saved(id: item.id, source: item.source, filename: item.filename, destination: item.destination,
                         received: item.received, total: item.total, state: state, reason: reason,
                         started: item.started, finished: item.finished, resumeData: item.resumeData)
        }
        file.save(saved)
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let name = Self.safeName(suggestedFilename) ?? L("Download")
        item(for: download)?.filename = name
        if response.expectedContentLength > 0 { item(for: download)?.total = response.expectedContentLength }
        if Settings.shared.confirmDangerousDownloads, Self.isDangerous(name) {
            let host = download.originalRequest?.url?.host ?? ""
            Dialogs.confirm(NSApp.keyWindow, title: String(format: L("“%@” can make changes to your Mac"), name),
                            message: String(format: L("Apps, installers and scripts can harm your Mac. Download it only if you trust %@."), host.isEmpty ? L("this site") : host),
                            ok: L("Download Anyway"), cancel: L("Cancel")) { ok in
                if ok {
                    self.chooseDestination(download, name: name, completionHandler: completionHandler)
                } else {
                    self.item(for: download)?.state = .cancelled
                    self.persist()
                    completionHandler(nil)
                }
            }
            return
        }
        chooseDestination(download, name: name, completionHandler: completionHandler)
    }

    static let dangerousExtensions: Set<String> = [
        "dmg", "pkg", "mpkg", "app", "command", "sh", "zsh", "bash", "tool", "terminal", "scpt", "applescript",
        "workflow", "action", "prefpane", "kext", "jar", "bin", "run", "exe", "msi", "bat", "ps1", "py", "pl", "rb",
    ]

    static func isDangerous(_ name: String) -> Bool {
        dangerousExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private func chooseDestination(_ download: WKDownload, name: String, completionHandler: @escaping (URL?) -> Void) {
        if Settings.shared.askDownloadLocation {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.directoryURL = Self.folder
            panel.begin { [weak self] result in
                guard result == .OK, let url = panel.url else {
                    self?.item(for: download)?.state = .cancelled
                    self?.persist()
                    completionHandler(nil)
                    return
                }
                try? FileManager.default.removeItem(at: url)
                self?.item(for: download)?.destination = url
                self?.item(for: download)?.filename = url.lastPathComponent
                self?.persist()
                completionHandler(url)
            }
            return
        }
        let url = Self.uniqueURL(name)
        item(for: download)?.destination = url
        item(for: download)?.filename = url.lastPathComponent
        persist()
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.state = .finished
        item.fraction = 1
        item.finished = Date()
        // The downloads button lights up: the file is ready.
        unseen = true
        item.resumeData = nil
        item.stopSampling()
        if item.received == 0, let path = item.destination?.path,
           let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 {
            item.received = size
        }
        if let path = item.destination?.path {
            // Bounces the Downloads stack in the Dock, like Safari.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: path)
        }
        persist()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        let e = error as NSError
        // A cancelled download's file is deleted, so there's nothing to resume.
        if let resumeData, item.state != .cancelled { item.resumeData = resumeData }
        item.stopSampling()
        // A pause stops the download the same way; it keeps its own state.
        if item.state == .active {
            item.state = e.code == NSURLErrorCancelled ? .cancelled : .failed(e.localizedDescription)
        }
        persist()
    }

    // MARK: Actions

    /// Stops a download for good and deletes the part already saved; Pause is for going on later.
    func cancel(_ item: DownloadItem) {
        let wasRunning = item.state == .active
        item.state = .cancelled
        item.stopSampling()
        item.resumeData = nil
        guard wasRunning, let download = item.download else {
            removePartialFile(of: item)
            persist()
            return
        }
        download.cancel { _ in
            DispatchQueue.main.async {
                self.removePartialFile(of: item)
                self.persist()
            }
        }
    }

    /// A cancelled download leaves the bytes it got under its final name, which would look like a broken file.
    private func removePartialFile(of item: DownloadItem) {
        guard item.state == .cancelled, let url = item.destination else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Stops a download where it is, to go on later.
    func pause(_ item: DownloadItem) {
        guard item.state == .active, let download = item.download else { return }
        item.state = .paused
        item.stopSampling()
        download.cancel { data in
            DispatchQueue.main.async {
                if let data {
                    item.resumeData = data
                } else {
                    // The server can't continue a download, so it will start over.
                    item.state = .failed(L("The site doesn't allow pausing. Download it again."))
                }
                self.persist()
            }
        }
    }

    /// Continues a paused, failed or cancelled download from where it stopped.
    func resume(_ item: DownloadItem) {
        guard let data = item.resumeData else { retry(item); return }
        let webView = item.download?.webView ?? Self.resumer
        item.resumeData = nil
        item.state = .active
        startTimer()
        webView.resumeDownload(fromResumeData: data) { [weak self] download in
            guard let self else { return }
            download.delegate = self
            // WebKit continues into the same file, so no destination is asked for again.
            item.download = download
            item.observe(download)
            self.persist()
        }
    }

    /// Downloads the same address again from the start, in place of this entry.
    func retry(_ item: DownloadItem) {
        guard let source = item.source, item.canRetry else { return }
        let webView = item.download?.webView ?? Self.resumer
        items.removeAll { $0 === item }
        webView.startDownload(using: URLRequest(url: source)) { [weak self] download in
            self?.track(download)
        }
    }

    func pauseAll() { active.forEach(pause) }

    /// Pauses every running download as Tacet quits, keeping what WebKit needs to resume it at the next launch.
    /// Waits two seconds at most.
    func pauseForQuit(done: @escaping () -> Void) {
        let running = active.filter { $0.download != nil }
        guard !running.isEmpty else { done(); return }
        let group = DispatchGroup()
        for item in running {
            group.enter()
            item.state = .paused
            item.stopSampling()
            item.download?.cancel { data in
                DispatchQueue.main.async {
                    if let data { item.resumeData = data } else { item.state = .failed(L("Stopped when Tacet quit")) }
                    group.leave()
                }
            }
        }
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            self.persist()
            self.file.flush()
            done()
        }
        group.notify(queue: .main, execute: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: finish)
    }
    func resumeAll() { items.filter { $0.state == .paused }.forEach(resume) }

    /// For resuming downloads whose tab has closed.
    private static let resumer = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

    func reveal(_ item: DownloadItem) {
        guard let url = item.destination else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func open(_ item: DownloadItem) {
        guard let url = item.destination, item.state == .finished else { return }
        NSWorkspace.shared.open(url)
    }

    /// A menu of the apps that can open the file, where the pointer is.
    func openWith(_ file: URL) {
        let menu = NSMenu()
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: file)
        for app in apps {
            let item = ActionMenuItem(FileManager.default.displayName(atPath: app.path)) {
                NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
            item.image = NSWorkspace.shared.icon(forFile: app.path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        guard !apps.isEmpty else { return }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func remove(_ item: DownloadItem) {
        if item.state == .active || item.state == .paused { cancel(item) }
        items.removeAll { $0 === item }
        persist()
    }

    /// Moves the downloaded file to the Trash and takes it off the list.
    func trash(_ item: DownloadItem) {
        if let url = item.destination { NSWorkspace.shared.recycle([url]) }
        remove(item)
    }

    func clearFinished() {
        items.removeAll { $0.state != .active && $0.state != .paused }
        persist()
    }

    static var folder: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    /// A file name the server suggested, reduced to a plain name that can't leave the Downloads folder.
    static func safeName(_ suggested: String) -> String? {
        let last = suggested.replacingOccurrences(of: ":", with: "-").split(separator: "/").last.map(String.init) ?? ""
        let name = String(last.drop { $0 == "." }).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// A free name in Downloads, also free of other downloads still in progress (their files don't exist yet).
    static func uniqueURL(_ name: String) -> URL {
        let inProgress = Set(shared.items.filter { $0.state == .active || $0.state == .paused }.compactMap { $0.destination?.path })
        var url = folder.appendingPathComponent(safeName(name) ?? L("Download"))
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) || inProgress.contains(url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}
