import Foundation
import Observation

/// Sites with Tacet Shield off for now, from "Site not working?". Pure, so the tests can try it
/// without touching the allowlist in your settings.
struct ShieldExceptions: Equatable {
    private(set) var sites: [String] = []

    /// A site as the allowlist keeps it: lowercased, without "www.".
    static func site(_ host: String) -> String {
        host.lowercased().replacingOccurrences(of: "www.", with: "", options: .anchored)
    }

    /// Whether `host` is one of `list` or a subdomain of one, the same match the allowlist uses.
    static func covers(_ list: [String], _ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return list.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func covers(_ host: String?) -> Bool { Self.covers(sites, host) }

    /// Returns false when the site was already off for now.
    @discardableResult
    mutating func add(_ host: String) -> Bool {
        let s = Self.site(host)
        guard !s.isEmpty, !sites.contains(s) else { return false }
        sites.append(s)
        return true
    }

    /// Ends every exception that covers `host`, and returns them, so pages on them can reload.
    @discardableResult
    mutating func remove(_ host: String) -> [String] {
        let gone = sites.filter { Self.covers([$0], host) }
        sites.removeAll { gone.contains($0) }
        return gone
    }

    /// "Keep Off": the exceptions covering `host` leave this list and join `allowlist`, which is returned sorted.
    mutating func keep(_ host: String, in allowlist: [String]) -> [String] {
        let kept = remove(host)
        return Array(Set(allowlist + kept)).sorted()
    }
}

/// The exceptions of this run of Tacet. Memory only, never saved, so Shield is back on for these
/// sites when Tacet quits; nothing about them is sent anywhere.
@Observable
final class ShieldTrial {
    static let shared = ShieldTrial()
    private(set) var exceptions = ShieldExceptions()

    var sites: [String] { exceptions.sites }
    func isOff(_ host: String?) -> Bool { exceptions.covers(host) }

    /// "Site not working?": Shield off on the site until Tacet quits; its open pages reload without it.
    func start(_ host: String) {
        if exceptions.add(host) { changed([ShieldExceptions.site(host)]) }
    }

    /// Shield back on: the site's pages reload with it.
    func turnBackOn(_ host: String) {
        let gone = exceptions.remove(host)
        if !gone.isEmpty { changed(gone) }
    }

    /// Keeps Shield off in the allowlist. The pages stay as they are, since Shield is off on them either way.
    func keepOff(_ host: String) {
        let s = Settings.shared
        let list = exceptions.keep(host, in: s.allowlist)
        if list != s.allowlist { s.allowlist = list }
    }

    private func changed(_ sites: [String]) {
        // Through settingChanged, so the spare web view a window keeps ready is made again with the new scripts.
        NotificationCenter.default.post(name: .settingChanged, object: self, userInfo: ["key": "shieldTrial", "sites": sites])
    }
}
