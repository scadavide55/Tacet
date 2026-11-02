import AppKit
import CommonCrypto
import CryptoKit
import UniformTypeIdentifiers
import WebKit

/// Everything Tacet keeps, in one file for another Mac: settings and plugins, history, bookmarks, Reading List,
/// highlights, Spaces, open tabs, saved groups, rules and automations, saved passwords, AI keys and the sites you're
/// signed in to. Since that's enough to get into your accounts, the whole file is encrypted with a password you choose
/// (AES-GCM, key from PBKDF2-SHA256); without it the file can't be read, and a forgotten password can't be recovered.
enum Backup {
    static let fileType = UTType(filenameExtension: "tacetbackup", conformingTo: .data) ?? .data
    static let rounds: UInt32 = 600_000

    /// The encrypted file as written to disk.
    struct Envelope: Codable {
        var tacetBackup = 1
        var kdf = "pbkdf2-sha256"
        var rounds: UInt32
        var salt: Data
        var box: Data
    }

    struct StoredCookie: Codable {
        var name, value, domain, path: String
        var expires: Date?
        var secure: Bool
        var httpOnly: Bool
        var sameSite: String?

        init(_ c: HTTPCookie) {
            name = c.name; value = c.value; domain = c.domain; path = c.path
            expires = c.expiresDate; secure = c.isSecure; httpOnly = c.isHTTPOnly
            sameSite = c.sameSitePolicy?.rawValue
        }

        var cookie: HTTPCookie? {
            var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
            if let expires { p[.expires] = expires }
            if secure { p[.secure] = "TRUE" }
            if httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let sameSite { p[.sameSitePolicy] = sameSite }
            return HTTPCookie(properties: p)
        }
    }

    /// What's inside, once decrypted.
    struct Contents: Codable {
        var version = UpdateChecker.currentVersion
        var date = Date()
        /// Settings and plugins, as SettingsTransfer writes them.
        var settings: Data?
        /// Tacet's data folder, file by file, by path inside it.
        var files: [String: Data] = [:]
        /// Saved passwords, as CSV.
        var passwords: String?
        var aiKeys: [String: String] = [:]
        /// Cookies of the main profile ("main") and of each profile, by its id.
        var cookies: [String: [StoredCookie]] = [:]
    }

    // MARK: Encryption

    static func key(_ password: String, salt: Data, rounds: UInt32) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        _ = salt.withUnsafeBytes { s in
            pw.withUnsafeBufferPointer { p in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                     pw.count, s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
            }
        }
        return SymmetricKey(data: out)
    }

    static func seal(_ contents: Contents, password: String) throws -> Data {
        let plain = try PropertyListEncoder().encode(contents)
        let packed = try (plain as NSData).compressed(using: .lzfse) as Data
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let box = try AES.GCM.seal(packed, using: key(password, salt: salt, rounds: rounds))
        return try JSONEncoder().encode(Envelope(rounds: rounds, salt: salt, box: box.combined!))
    }

    enum Failure: LocalizedError {
        case notABackup, wrongPassword
        var errorDescription: String? {
            switch self {
            case .notABackup: L("This isn't a Tacet backup.")
            case .wrongPassword: L("The password is wrong, or the file is damaged.")
            }
        }
    }

    static func open(_ data: Data, password: String) throws -> Contents {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data), env.tacetBackup == 1 else { throw Failure.notABackup }
        guard let box = try? AES.GCM.SealedBox(combined: env.box),
              let packed = try? AES.GCM.open(box, using: key(password, salt: env.salt, rounds: env.rounds)),
              let plain = try? (packed as NSData).decompressed(using: .lzfse) as Data,
              let contents = try? PropertyListDecoder().decode(Contents.self, from: plain) else { throw Failure.wrongPassword }
        return contents
    }

    // MARK: The data folder

    /// Folders that come back by themselves (icons, downloaded plugins) or belong to apps installed from sites.
    static let skipped: Set<String> = ["Favicons", "Plugins", "WebApps", "Backup before 1.5.2", "public_suffix_list.txt"]

    static func readFolder(_ root: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        let base = root.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count))
            if let first = rel.split(separator: "/").first, skipped.contains(String(first)) {
                walker.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, let data = try? Data(contentsOf: url) else { continue }
            out[rel] = data
        }
        return out
    }

    /// Where restored files wait for the next launch, beside the data folder.
    static var pending: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumen Restore", isDirectory: true)
    }

    /// Called first thing at launch, before anything reads the data folder: puts restored files in place.
    static func applyPendingRestore() {
        let fm = FileManager.default
        let staging = pending
        guard fm.fileExists(atPath: staging.path), !WebApp.isActive else { return }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumen", isDirectory: true)
        let files = readFolder(staging)
        for (rel, data) in files {
            let target = support.appendingPathComponent(rel)
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A database's journal from before would not match the restored database.
            if rel.hasSuffix(".sqlite") {
                for suffix in ["-wal", "-shm"] where files[rel + suffix] == nil { try? fm.removeItem(atPath: target.path + suffix) }
            }
            try? data.write(to: target, options: .atomic)
        }
        try? fm.removeItem(at: staging)
    }

    // MARK: Backing up

    @MainActor
    static func backUp() {
        guard let password = askNewPassword() else { return }
        PasswordStore.shared.authenticate(reason: L("back up your saved passwords")) { ok in
            guard ok else { return }
            Task { @MainActor in
                // Everything still waiting to be written goes to disk first.
                History.shared.flush()
                PageText.shared.flush()
                Session.shared.saveNow()
                Spaces.shared.saveNow()
                StoredFiles.flushAll()
                var contents = Contents()
                contents.settings = SettingsTransfer.make()
                contents.passwords = PasswordStore.shared.logins.isEmpty ? nil : PasswordStore.shared.exportCSV()
                for p in AIProvider.allCases { if let k = AIKeys.get(p) { contents.aiKeys[p.rawValue] = k } }
                contents.cookies["main"] = await cookies(of: .default())
                for profile in Settings.shared.profiles {
                    contents.cookies[profile.id.uuidString] = await cookies(of: WKWebsiteDataStore(forIdentifier: profile.id))
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [fileType]
                panel.nameFieldStringValue = "Tacet Backup " + Date().formatted(.iso8601.year().month().day()) + ".tacetbackup"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let finished = contents
                let data = await Task.detached(priority: .userInitiated) { () -> Result<Data, Error> in
                    var all = finished
                    all.files = readFolder(Paths.support)
                    return Result { try seal(all, password: password) }
                }.value
                do {
                    try data.get().write(to: url, options: .atomic)
                    let done = NSAlert()
                    done.messageText = L("Backup saved")
                    done.informativeText = L("Keep the password safe: without it the backup can't be opened. On the other Mac, choose Settings › General › Restore from Backup…")
                    done.runModal()
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    @MainActor
    private static func cookies(of store: WKWebsiteDataStore) async -> [StoredCookie] {
        await withCheckedContinuation { done in
            store.httpCookieStore.getAllCookies { done.resume(returning: $0.map(StoredCookie.init)) }
        }
    }

    // MARK: Restoring

    @MainActor
    static func restore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [fileType]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        guard let password = askPassword(title: L("Enter the backup's password"), confirm: false) else { return }
        Task { @MainActor in
            let opened = await Task.detached(priority: .userInitiated) { Result { try open(data, password: password) } }.value
            let contents: Contents
            do { contents = try opened.get() } catch {
                let a = NSAlert()
                a.messageText = error.localizedDescription
                a.runModal()
                return
            }
            let confirm = NSAlert()
            confirm.messageText = L("Replace everything in Tacet with this backup?")
            confirm.informativeText = String(format: L("From Tacet %@, %@. Your tabs, history, bookmarks, settings, passwords and sign-ins on this Mac are replaced. Tacet restarts to finish."),
                                             contents.version, contents.date.formatted(date: .abbreviated, time: .shortened))
            confirm.addButton(withTitle: L("Restore and Restart"))
            confirm.addButton(withTitle: L("Cancel"))
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            if let s = contents.settings, let file = SettingsTransfer.read(s) { await SettingsTransfer.apply(file) }
            if let csv = contents.passwords { _ = PasswordStore.shared.importCSV(csv) }
            for (raw, key) in contents.aiKeys { if let p = AIProvider(rawValue: raw) { AIKeys.set(key, for: p) } }
            for (id, list) in contents.cookies {
                let store: WKWebsiteDataStore = id == "main" ? .default() : UUID(uuidString: id).map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default()
                for c in list.compactMap(\.cookie) { await store.httpCookieStore.setCookie(c) }
            }
            // The files go in at the next launch, before Tacet reads them, so nothing written on quitting replaces them.
            let fm = FileManager.default
            try? fm.removeItem(at: pending)
            for (rel, data) in contents.files where !rel.contains("..") {
                let target = pending.appendingPathComponent(rel)
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: target, options: .atomic)
            }
            SettingsTransfer.restart()
        }
    }

    // MARK: Asking

    @MainActor
    private static func askNewPassword() -> String? {
        askPassword(title: L("Choose a password for the backup"), confirm: true)
    }

    /// A password field (and a second one to type it again, for a new password). At least 8 characters.
    @MainActor
    private static func askPassword(title: String, confirm: Bool) -> String? {
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = confirm
                ? L("The backup holds your passwords and sign-ins, so it's encrypted with this password. Without it the backup can't be opened, and it can't be recovered.")
                : ""
            let first = NSSecureTextField(frame: NSRect(x: 0, y: confirm ? 30 : 0, width: 260, height: 24))
            first.placeholderString = L("Password")
            let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            second.placeholderString = L("Type it again")
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: confirm ? 54 : 24))
            box.addSubview(first)
            if confirm { box.addSubview(second) }
            alert.accessoryView = box
            alert.window.initialFirstResponder = first
            alert.addButton(withTitle: L("OK"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let pw = first.stringValue
            if confirm && pw.count < 8 { warn(L("Use at least 8 characters.")); continue }
            if confirm && pw != second.stringValue { warn(L("The two passwords don't match.")); continue }
            if pw.isEmpty { continue }
            return pw
        }
    }

    @MainActor
    private static func warn(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.runModal()
    }
}
