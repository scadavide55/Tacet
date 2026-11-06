import Observation
import AppKit
import LocalAuthentication
import Security
import CryptoKit

struct SavedLogin: Identifiable, Hashable {
    var id: String { host + "\u{1}" + username }
    let host: String
    let username: String
}

/// Website passwords kept in the macOS Keychain as internet passwords. Reading one
/// requires Touch ID or the Mac's password; listing accounts does not.
@Observable
final class PasswordStore {
    static let shared = PasswordStore()
    /// Named before Lumen became Tacet; kept so saved passwords are still found.
    static let marker = "Lumen web password"

    private(set) var logins: [SavedLogin] = []
    @ObservationIgnored private var unlockedUntil = Date.distantPast

    private init() { reload() }

    func reload() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrDescription as String: Self.marker,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            logins = []
            return
        }
        logins = items.compactMap { item in
            guard let host = item[kSecAttrServer as String] as? String else { return nil }
            return SavedLogin(host: host, username: item[kSecAttrAccount as String] as? String ?? "")
        }
        .sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    /// Accounts for a site, including its subdomains and parent domain (accounts.example.com ↔ example.com).
    func logins(for host: String?) -> [SavedLogin] {
        guard let host = host?.lowercased() else { return [] }
        let site = Self.site(host)
        return logins.filter { Self.site($0.host) == site }
            .sorted { ($0.host == host ? 0 : 1, $0.username) < ($1.host == host ? 0 : 1, $1.username) }
    }

    /// The registrable part of a host: "www.bbc.co.uk" → "bbc.co.uk", "mail.google.com" → "google.com".
    /// Sites on a shared domain stay apart: "alice.github.io" ≠ "evil.github.io".
    static func site(_ host: String) -> String { PublicSuffix.registrable(host) }

    /// Whether a frame embedded in a page (a sign-in widget, a single sign-on box) may be offered and filled with a
    /// login saved for `savedHost`: only a frame on HTTPS, on the same site as the login, whatever page it's in.
    static func frameMayFill(scheme: String, frameHost: String, savedHost: String) -> Bool {
        let h = frameHost.lowercased()
        return scheme.lowercased() == "https" && !h.isEmpty && site(h) == site(savedHost.lowercased())
    }

    private func baseQuery(_ host: String, _ username: String) -> [String: Any] {
        [kSecClass as String: kSecClassInternetPassword,
         kSecAttrServer as String: host,
         kSecAttrAccount as String: username,
         kSecAttrDescription as String: Self.marker]
    }

    /// Saves or updates a password. Returns false if the Keychain refused.
    @discardableResult
    func save(host: String, username: String, password: String, reload shouldReload: Bool = true) -> Bool {
        let host = host.lowercased()
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(host, username) as CFDictionary, update as CFDictionary)
        // An item written by an earlier build (Tacet is signed ad hoc, so every build is a different app)
        // can refuse the update; it is replaced instead.
        if status != errSecSuccess && status != errSecItemNotFound {
            SecItemDelete(baseQuery(host, username) as CFDictionary)
            status = errSecItemNotFound
        }
        if status == errSecItemNotFound {
            var add = baseQuery(host, username)
            add[kSecValueData as String] = data
            add[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS
            add[kSecAttrLabel as String] = host
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if shouldReload { reload() }
        return status == errSecSuccess
    }

    func delete(_ login: SavedLogin) {
        SecItemDelete(baseQuery(login.host, login.username) as CFDictionary)
        reload()
    }

    /// Reads a password without asking. Only for code paths that already authenticated.
    private func readPassword(_ login: SavedLogin) -> String? {
        var query = baseQuery(login.host, login.username)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether the saved password matches, without asking for Touch ID (used to decide whether to offer saving).
    func matches(host: String, username: String, password: String) -> Bool {
        readPassword(SavedLogin(host: host.lowercased(), username: username)) == password
    }

    /// Asks for Touch ID or the Mac password, at most once every five minutes.
    func authenticate(reason: String, done: @escaping (Bool) -> Void) {
        if Date() < unlockedUntil { done(true); return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { done(true); return }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async {
                if ok { self.unlockedUntil = Date().addingTimeInterval(300) }
                done(ok)
            }
        }
    }

    func lock() { unlockedUntil = .distantPast }

    /// A strong password in Apple's style: three groups of six, with an uppercase letter and a digit.
    static func generate() -> String {
        let lower = Array("abcdefghijkmnopqrstuvwxyz"), upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), digits = Array("23456789")
        func random(_ n: Int) -> Int {
            var x: UInt32 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 4, &x)
            return Int(x % UInt32(n))
        }
        var chars = (0..<18).map { _ in lower[random(lower.count)] }
        var spots = Array(0..<18)
        let up = spots.remove(at: random(spots.count))
        let dig = spots.remove(at: random(spots.count))
        chars[up] = upper[random(upper.count)]
        chars[dig] = digits[random(digits.count)]
        return stride(from: 0, to: 18, by: 6).map { String(chars[$0..<$0 + 6]) }.joined(separator: "-")
    }

    /// After Touch ID, the password is read off the main thread (the Keychain can wait on a macOS prompt) and handed
    /// back on the main thread.
    func password(for login: SavedLogin, reason: String, done: @escaping (String?) -> Void) {
        authenticate(reason: reason) { ok in
            guard ok else { done(nil); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let password = self.readPassword(login)
                DispatchQueue.main.async { done(password) }
            }
        }
    }

    // MARK: Password check

    enum Issue: String, Comparable {
        /// unchecked: the breach list couldn't be reached for it, so "not breached" isn't known.
        case breached, reused, weak, unchecked
        static func < (a: Issue, b: Issue) -> Bool { all.firstIndex(of: a)! < all.firstIndex(of: b)! }
        private static let all: [Issue] = [.breached, .reused, .weak, .unchecked]
    }

    /// Looks at every saved password after one Touch ID: found in a data breach (via Have I Been Pwned, which only
    /// ever sees the first 5 characters of the password's SHA-1 hash), used on more than one site, or easy to guess.
    /// Nothing is stored; the result is shown and forgotten.
    func checkup(done: @escaping ([SavedLogin.ID: Set<Issue>]?) -> Void) {
        authenticate(reason: L("check your saved passwords")) { ok in
            guard ok else { done(nil); return }
            let logins = self.logins
            Task.detached(priority: .userInitiated) {
                // Read here, off the main thread: the Keychain can wait on a macOS prompt.
                let all = logins.compactMap { login in self.readPassword(login).map { (login, $0) } }
                var issues: [SavedLogin.ID: Set<Issue>] = [:]
                var sites: [String: Set<String>] = [:]
                for (login, pw) in all { sites[pw, default: []].insert(Self.site(login.host)) }
                for (login, pw) in all {
                    if (sites[pw]?.count ?? 0) > 1 { issues[login.id, default: []].insert(.reused) }
                    if Self.isWeak(pw) { issues[login.id, default: []].insert(.weak) }
                }
                let (breached, unchecked) = await Self.breached(Set(all.map(\.1)))
                for (login, pw) in all where breached.contains(pw) { issues[login.id, default: []].insert(.breached) }
                for (login, pw) in all where unchecked.contains(pw) { issues[login.id, default: []].insert(.unchecked) }
                let result = issues
                await MainActor.run { done(result) }
            }
        }
    }

    static func isWeak(_ pw: String) -> Bool {
        let kinds = [pw.contains(where: \.isLowercase), pw.contains(where: \.isUppercase),
                     pw.contains(where: \.isNumber), pw.contains { !$0.isLetter && !$0.isNumber }].filter { $0 }.count
        return pw.count < 8 || (pw.count < 12 && kinds < 3) || Set(pw).count < 4
    }

    /// The passwords that appear in Have I Been Pwned's list of breached passwords (k-anonymity: only a 5-character
    /// hash prefix is sent, and the answer is padded so its size doesn't reveal anything either).
    /// Also returns the passwords whose part of the list couldn't be downloaded, so they aren't shown as safe.
    static func breached(_ passwords: Set<String>) async -> (found: Set<String>, unchecked: Set<String>) {
        var byPrefix: [String: [(suffix: String, password: String)]] = [:]
        for pw in passwords {
            let hash = Insecure.SHA1.hash(data: Data(pw.utf8)).map { String(format: "%02X", $0) }.joined()
            byPrefix[String(hash.prefix(5)), default: []].append((String(hash.dropFirst(5)), pw))
        }
        let session = URLSession(configuration: .ephemeral)
        // A session is kept by the system until it's let go of.
        defer { session.finishTasksAndInvalidate() }
        var found = Set<String>(), unchecked = Set<String>()
        for (prefix, entries) in byPrefix {
            guard let url = URL(string: "https://api.pwnedpasswords.com/range/" + prefix) else { continue }
            var request = URLRequest(url: url)
            request.setValue("true", forHTTPHeaderField: "Add-Padding")
            request.timeoutInterval = 15
            guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else {
                unchecked.formUnion(entries.map(\.password))
                continue
            }
            var counts: [String: Int] = [:]
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":")
                if parts.count == 2 { counts[String(parts[0])] = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
            }
            for e in entries where (counts[e.suffix] ?? 0) > 0 { found.insert(e.password) }
        }
        return (found, unchecked)
    }

    // MARK: CSV

    /// Imports a CSV exported by Apple Passwords, Safari, Chrome, Firefox, Bitwarden or 1Password.
    func importCSV(_ text: String) -> Int {
        let rows = CSV.parse(text)
        guard let header = rows.first?.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }) else { return 0 }
        func col(_ names: [String]) -> Int? { header.firstIndex { names.contains($0) } }
        guard let u = col(["url", "login_uri", "website", "web site", "origin", "hostname"]),
              let user = col(["username", "login_username", "login", "user", "email"]),
              let pass = col(["password", "login_password"]) else { return 0 }
        var added = 0
        for row in rows.dropFirst() where row.count > max(u, user, pass) {
            let raw = row[u].trimmingCharacters(in: .whitespaces)
            let url = URL(string: raw.contains("://") ? raw : "https://" + raw)
            guard let host = url?.host, !row[pass].isEmpty else { continue }
            if save(host: host, username: row[user], password: row[pass], reload: false) { added += 1 }
        }
        reload()
        return added
    }

    /// CSV in the format the Passwords app imports (File › Import Passwords).
    func exportCSV() -> String {
        var out = "Title,URL,Username,Password,Notes,OTPAuth\n"
        for l in logins {
            let fields = [l.host, "https://\(l.host)/", l.username, readPassword(l) ?? "", "", ""]
            out += fields.map(CSV.escape).joined(separator: ",") + "\n"
        }
        return out
    }
}

enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c == "\n" {
                row.append(field); field = ""
                if row.count > 1 || !(row.first ?? "").isEmpty { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        return rows
    }

    static func escape(_ s: String) -> String {
        s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}

// MARK: - Other password managers

/// A password manager app installed on this Mac, and how it can fill passwords outside its own browser extension.
struct ExternalPasswordManager: Identifiable, Hashable {
    enum Fill: Hashable {
        /// The app fills any field system-wide with a shortcut (1Password Universal Autofill, KeePassXC Auto-Type).
        /// An empty string means the shortcut is one the user picked in that app.
        case shortcut(String)
        /// No system-wide filling: Tacet opens the app so you can copy the password.
        case openApp
    }

    let id: String
    let name: String
    let appURL: URL
    let fill: Fill

    var icon: NSImage { NSWorkspace.shared.icon(forFile: appURL.path) }

    private static let known: [(String, String, Fill)] = [
        ("1Password", "1Password.app", .shortcut("⌘\\")),
        ("1Password 7", "1Password 7.app", .shortcut("⌘\\")),
        ("KeePassXC", "KeePassXC.app", .shortcut("")),
        ("Bitwarden", "Bitwarden.app", .openApp),
        ("Proton Pass", "Proton Pass.app", .openApp),
        ("Enpass", "Enpass.app", .openApp),
        ("LastPass", "LastPass.app", .openApp),
        ("Dashlane", "Dashlane.app", .openApp),
        ("NordPass", "NordPass.app", .openApp),
        ("Strongbox", "Strongbox.app", .openApp),
    ]

    /// The last `detect()` result, so sign-in fields don't search the disk each time they're focused.
    private static var detected: [ExternalPasswordManager]?

    static func detect() -> [ExternalPasswordManager] {
        let folders = ["/Applications", NSHomeDirectory() + "/Applications", "/Applications/Setapp"]
        let found = known.compactMap { name, file, fill -> ExternalPasswordManager? in
            for folder in folders {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: url.path) {
                    return ExternalPasswordManager(id: Bundle(url: url)?.bundleIdentifier ?? file, name: name, appURL: url, fill: fill)
                }
            }
            return nil
        }
        detected = found
        return found
    }

    static var current: ExternalPasswordManager? {
        let id = Settings.shared.passwordManager
        guard !id.isEmpty else { return nil }
        return (detected ?? detect()).first { $0.id == id }
    }

    func open() { NSWorkspace.shared.open(appURL) }
}
