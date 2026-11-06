import Foundation
import os

/// What Tacet notes about itself for Console, and the same lines kept in memory for Help › Copy Diagnostic Log, which
/// can't read the system log without entitlements. Addresses are cut to their site and file names to their type:
/// paths, queries and names can hold personal data, and a diagnostic log gets pasted into public bug reports.
enum Diagnostics {
    enum Category: String {
        case webProcess, blocking, downloads, updates
    }

    static let subsystem = "com.lumen.browser"
    private static let loggers: [Category: Logger] = [
        .webProcess: Logger(subsystem: subsystem, category: Category.webProcess.rawValue),
        .blocking: Logger(subsystem: subsystem, category: Category.blocking.rawValue),
        .downloads: Logger(subsystem: subsystem, category: Category.downloads.rawValue),
        .updates: Logger(subsystem: subsystem, category: Category.updates.rawValue),
    ]

    /// This run's events, newest last.
    static let recent = LogRing(capacity: 300)

    /// Notes an event. `event` and `detail` must never hold an address, a path or a file name: pass `site` for the
    /// address, and `file(_:size:)` or `code(_:)` for the rest. That is why the whole line can be public in Console.
    static func log(_ category: Category, _ event: String, site url: URL? = nil, _ detail: String = "",
                    level: OSLogType = .default) {
        var line = event
        if let url { line += " " + site(url) }
        if !detail.isEmpty { line += " " + detail }
        loggers[category]?.log(level: level, "\(line, privacy: .public)")
        recent.append("[\(category.rawValue)] " + line)
    }

    /// Only the site of an address: "https://www.bbc.co.uk/news?id=1" → "bbc.co.uk". An address without a host
    /// (file:, data:, about:) gives just its scheme.
    static func site(_ url: URL?) -> String {
        guard let url else { return "-" }
        guard let host = url.host, !host.isEmpty else { return url.scheme?.lowercased() ?? "-" }
        let site = PublicSuffix.registrable(host)
        // Anything a host can't hold is dropped, so nothing else of the address gets through.
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-:[]")
        let clean = String(site.lowercased().filter { allowed.contains($0) })
        return clean.isEmpty ? "-" : clean
    }

    /// A file's type and size, never its name: "report.pdf", 1200000 → "pdf 1.2 MB".
    static func file(_ name: String?, size: Int64? = nil) -> String {
        let ext = ((name ?? "") as NSString).pathExtension.lowercased()
        // A long or odd "extension" is part of the name, so it isn't shown.
        let kind = ext.isEmpty ? "no extension"
            : ext.count <= 8 && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? ext : "other"
        guard let size, size > 0 else { return kind }
        return kind + " " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// An error's domain and code: its description can name the file or address it was about.
    static func code(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.domain) \(e.code)"
    }

    /// The text Copy Diagnostic Log puts on the clipboard: what this Tacet runs on, then this run's events.
    static func report(_ lines: [String]? = nil) -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var header = [
            "Tacet \(UpdateChecker.currentVersion)",
            "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            "Architecture: \(architecture)",
        ]
        let events = lines ?? recent.lines
        header.append(events.isEmpty ? "No events yet." : "\(events.count) events, oldest first:")
        return (header + [""] + events).joined(separator: "\n")
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        // An Intel build on Apple silicon runs under Rosetta, which explains slowness that wouldn't happen natively.
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        return rosetta ? "x86_64 (Rosetta)" : "x86_64"
        #endif
    }
}

/// The last few hundred log lines with their time. Logged from any thread, hence the lock.
final class LogRing {
    let capacity: Int
    private var storage: [String] = []
    private var next = 0
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    init(capacity: Int) { self.capacity = max(1, capacity) }

    func append(_ line: String, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let stamped = formatter.string(from: date) + " " + line
        // Once full, the oldest line is overwritten instead of shifting the whole array.
        if storage.count < capacity {
            storage.append(stamped)
        } else {
            storage[next] = stamped
        }
        next = (next + 1) % capacity
    }

    /// Oldest first.
    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        guard storage.count == capacity else { return storage }
        return Array(storage[next...] + storage[..<next])
    }
}
