import Foundation
import Network
import WebKit

/// A proxy a profile's pages connect through. Anything incomplete means a direct connection.
struct ProfileProxy: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case none, socks5, httpConnect

        /// A kind added by a newer Tacet reads as no proxy, rather than failing to read every profile.
        init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
        }
    }

    var kind = Kind.none
    var host = ""
    var port = 0

    init(kind: Kind = .none, host: String = "", port: Int = 0) {
        self.kind = kind
        self.host = host
        self.port = port
    }

    // Each key may be missing, so a hand-edited or partial value still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .none
        host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? ""
        port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? 0
    }

    /// The host without spaces, or the brackets around an IPv6 address.
    var cleanHost: String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        return h
    }

    var isValid: Bool {
        let h = cleanHost
        return kind != .none && !h.isEmpty && !h.contains(where: \.isWhitespace) && (1...65535).contains(port)
    }

    /// “host:port”, for showing which proxy is in use; nil when the profile connects directly.
    var address: String? {
        guard isValid else { return nil }
        let h = cleanHost
        return h.contains(":") ? "[\(h)]:\(port)" : "\(h):\(port)"
    }

    /// What WebKit is given: one configuration, or none for a direct connection.
    var configurations: [ProxyConfiguration] {
        guard isValid, let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return [] }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(cleanHost), port: p)
        switch kind {
        case .socks5: return [ProxyConfiguration(socksv5Proxy: endpoint)]
        case .httpConnect: return [ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)]
        case .none: return []
        }
    }
}

/// Gives each profile's data store the proxy set for it in Settings › Profiles.
enum ProfileProxies {
    /// What each profile's store was last given, so renaming a profile doesn't reset its connections.
    private static var applied: [UUID: ProfileProxy?] = [:]

    /// Sets the store's proxies. Private windows' stores are never touched: they don't belong to a profile,
    /// and a proxy there would outlive the window's promise to keep nothing.
    @discardableResult
    static func apply(_ proxy: ProfileProxy?, to store: WKWebsiteDataStore) -> Bool {
        guard store.isPersistent, store != .default() else { return false }
        store.proxyConfigurations = proxy?.configurations ?? []
        return true
    }

    /// A window's store was just made for this profile.
    static func prepare(_ profile: Profile, store: WKWebsiteDataStore) {
        // updateValue, because assigning nil would forget the profile instead of recording “no proxy”.
        if apply(profile.proxy, to: store) { applied.updateValue(effective(profile.proxy), forKey: profile.id) }
    }

    /// Profiles changed: open windows whose profile's proxy changed get the new one.
    static func refresh() {
        for profile in Settings.shared.profiles {
            let proxy = effective(profile.proxy)
            // Only profiles with a window open have a store to change; the rest get theirs when one opens.
            guard let last = applied[profile.id], last != proxy else { continue }
            let stores = WindowRegistry.shared.browsers.filter { !$0.isPrivate && $0.profileID == profile.id }.map(\.dataStore)
            for store in stores { apply(proxy, to: store) }
            applied.updateValue(proxy, forKey: profile.id)
        }
    }

    /// Incomplete settings count as no proxy, so editing them doesn't reapply anything until they work.
    private static func effective(_ proxy: ProfileProxy?) -> ProfileProxy? { proxy?.isValid == true ? proxy : nil }
}
