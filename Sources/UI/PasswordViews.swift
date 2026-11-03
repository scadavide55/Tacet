import SwiftUI
import UniformTypeIdentifiers

/// Saved accounts under a focused sign-in field.
struct LoginMenuView: View {
    var tab: Tab
    let menu: Tab.LoginMenu
    @State private var hover: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let strong = menu.strongPassword {
                Button { tab.fillStrong(strong) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "key.viewfinder").foregroundStyle(.tint).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Use Strong Password").font(.system(size: 13, weight: .medium))
                            Text(strong).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                    .background(hover == "strong" ? Color.accentColor.opacity(0.15) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 ? "strong" : nil }
            }
            ForEach(menu.logins) { login in
                Button { tab.fill(login) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill").foregroundStyle(.tint).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(login.username.isEmpty ? L("(no username)") : login.username).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(login.host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background(hover == login.id ? Color.accentColor.opacity(0.15) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 ? login.id : nil }
            }
            if let ext = ExternalPasswordManager.current {
                if !menu.logins.isEmpty { Divider() }
                ExternalManagerRow(manager: ext)
            }
            Divider()
            SettingsLink {
                Label("Manage Passwords…", systemImage: "gearshape").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).frame(height: 30)
            }
            .buttonStyle(.plain)
        }
        .frame(width: menu.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .offset(x: menu.origin.x, y: menu.origin.y)
        .onExitCommand { tab.loginMenu = nil }
    }
}

private struct ExternalManagerRow: View {
    let manager: ExternalPasswordManager

    var body: some View {
        Button { manager.open() } label: {
            HStack(spacing: 10) {
                Image(nsImage: manager.icon).resizable().frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    switch manager.fill {
                    case .shortcut(let keys) where !keys.isEmpty:
                        Text(String(format: L("Fill with %@: press %@"), manager.name, keys)).font(.system(size: 12.5, weight: .medium))
                    case .shortcut:
                        Text(String(format: L("Fill with %@: use its Auto-Type shortcut"), manager.name)).font(.system(size: 12.5, weight: .medium))
                    case .openApp:
                        Text(String(format: L("Open %@ to copy your password"), manager.name)).font(.system(size: 12.5, weight: .medium))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Save password?" after a sign-in.
struct SavePasswordBanner: View {
    var tab: Tab
    let pending: Tab.PendingLogin

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill").font(.system(size: 18)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(pending.isUpdate ? L("Update the saved password?") : L("Save this password?")).font(.system(size: 13, weight: .semibold))
                Text(pending.username.isEmpty ? pending.host : "\(pending.username) · \(pending.host)")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if !pending.isUpdate {
                Button("Never for This Site") { tab.neverSavePending() }.buttonStyle(.borderless).font(.system(size: 12))
            }
            Button("Not Now") { tab.pendingSave = nil }
            Button(pending.isUpdate ? "Update" : "Save") { tab.savePending() }.buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .padding(10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// A site asked for a passkey: Tacet can't use passkeys yet, so it offers to sign in with Safari and bring the
/// sign-in back, or to carry on with the site's other ways in.
struct PasskeyBanner: View {
    var tab: Tab
    let help: Tab.PasskeyHelp

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.badge.key.fill").font(.system(size: 18)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    switch help.stage {
                    case .ask:
                        Button("Sign In with Safari") { tab.signInWithSafari() }.buttonStyle(.borderedProminent)
                    case .inSafari, .failed:
                        Button("I'm Signed In") { tab.bringSignInFromSafari() }.buttonStyle(.borderedProminent)
                        Button("Open Safari Again") { tab.signInWithSafari() }
                    case .importing:
                        ProgressView().controlSize(.small)
                    case .needsAccess:
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                        Button("Try Again") { tab.bringSignInFromSafari() }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(.top, 5)
            }
            Spacer(minLength: 8)
            Button { tab.passkeyHelp = nil } label: { Label("Close", systemImage: "xmark").labelStyle(.iconOnly).font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Use another way to sign in")
        }
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .padding(10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var title: String {
        switch help.stage {
        case .ask: L("Tacet can't use passkeys yet")
        case .inSafari, .importing: L("Sign in with your passkey in Safari")
        case .failed: L("The sign-in didn't come across")
        case .needsAccess: L("Tacet needs Full Disk Access")
        }
    }

    private var detail: String {
        switch help.stage {
        case .ask: String(format: L("Sign in to %@ in Safari with Touch ID, and Tacet brings the sign-in back here. Or close this and choose another way to sign in, like a password or a code."), help.site)
        case .inSafari, .importing: L("When you're signed in, come back and click I'm Signed In.")
        case .failed(let reason): reason
        case .needsAccess: L("Safari keeps its sign-ins where only apps with Full Disk Access can read them. Turn on Tacet in the list, then try again.")
        }
    }
}

/// "You didn't send what you wrote here": text kept from an earlier visit, to put back.
struct DraftBanner: View {
    var tab: Tab
    /// The drafts as they were when the banner appeared: while it animates away the tab's list is already empty.
    let drafts: [Draft]

    var body: some View {
        if let first = drafts.first { content(first) }
    }

    private func content(_ first: Draft) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.badge.clock").font(.system(size: 18)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(drafts.count == 1 ? L("You didn't send what you wrote here") : String(format: L("You didn't send %d texts you wrote here"), drafts.count))
                    .font(.system(size: 13, weight: .semibold))
                Text((first.label.isEmpty ? "" : first.label + " · ") + first.date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text(first.text.split(whereSeparator: \.isNewline).joined(separator: " "))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    Button("Put It Back") { tab.restoreDrafts() }.buttonStyle(.borderedProminent)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(drafts.map(\.text).joined(separator: "\n\n"), forType: .string)
                        tab.draftOffer = []
                    }
                    Button("Discard") { tab.discardDrafts() }
                }
                .padding(.top, 5)
            }
            Spacer(minLength: 8)
            Button { tab.draftOffer = [] } label: { Label("Close", systemImage: "xmark").labelStyle(.iconOnly).font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Not now")
        }
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .padding(10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Warning shown when a password field appears on an unencrypted page.
struct InsecurePasswordBanner: View {
    var tab: Tab

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("This page isn't secure. Passwords you type here can be read by others on your network.")
                .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { tab.insecureWarning = false } label: { Label("Close", systemImage: "xmark").labelStyle(.iconOnly).font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: 560)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.orange.opacity(0.4)))
        .padding(10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Covers a locked window: a private one after Tacet goes to the background, or any window locked from the File menu.
struct PrivateLockView: View {
    @Environment(BrowserState.self) var b

    var body: some View {
        ZStack {
            VisualEffect(material: .fullScreenUI, blending: .withinWindow)
            Color(red: 0.2, green: 0.12, blue: 0.36).opacity(0.5)
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.white)
                Text(b.isPrivate ? "Private window locked" : "Window locked").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                Text("Unlock with Touch ID or your Mac password to see these tabs.").foregroundStyle(.white.opacity(0.75))
                Button("Unlock") { b.unlock() }.controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onAppear { if NSApp.isActive && !b.lockedByUser { b.unlock() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Only the front window asks, so several locked windows don't stack Touch ID prompts,
            // and a window you locked yourself waits for you.
            DispatchQueue.main.async { if b.window?.isKeyWindow == true && !b.lockedByUser { b.unlock() } }
        }
    }
}

// MARK: - Settings

struct PasswordsPane: View {
    @Bindable private var s = Settings.shared
    private var store = PasswordStore.shared
    @State private var query = ""
    @State private var revealed: [String: String] = [:]
    @State private var message: String?
    @State private var managers = ExternalPasswordManager.detect()
    @State private var issues: [SavedLogin.ID: Set<PasswordStore.Issue>]?
    @State private var checking = false

    private var filtered: [SavedLogin] {
        let q = query.lowercased()
        return q.isEmpty ? store.logins : store.logins.filter { $0.host.contains(q) || $0.username.lowercased().contains(q) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Password manager", selection: $s.passwordManager) {
                    Text("Tacet (Keychain and Touch ID)").tag("")
                    ForEach(managers) { m in Text(m.name).tag(m.id) }
                }
                Toggle("Offer to save passwords", isOn: $s.savePasswords).disabled(!s.passwordManager.isEmpty)
                Toggle("Suggest saved passwords on sign-in pages", isOn: $s.autofillPasswords)
                Toggle(isOn: $s.suggestStrongPasswords) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggest strong passwords")
                        Text("On sign-up and change-password pages, offer a random password like abcdEf-ghijk2-lmnopq.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Passwords are stored in your Mac's Keychain, encrypted by macOS. Tacet asks for Touch ID or your Mac password before filling or showing one.")
            }

            Section {
                // Always there, so it's easy to find; with nothing saved there's nothing to check yet.
                PasswordCheckRow(issues: issues, checking: checking, empty: store.logins.isEmpty) {
                    checking = true
                    store.checkup { result in
                        checking = false
                        if let result { issues = result }
                    }
                }
                if store.logins.isEmpty {
                    Text("No saved passwords yet.").foregroundStyle(.secondary)
                } else {
                    TextField("Search passwords", text: $query)
                    ForEach(filtered) { login in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(login.host)
                                Text(login.username.isEmpty ? L("(no username)") : login.username).font(.caption).foregroundStyle(.secondary)
                            }
                            if let found = issues?[login.id], let worst = found.min() {
                                Image(systemName: worst == .breached ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(worst == .breached ? .red : .orange)
                                    .help(found.sorted().map(PasswordCheckRow.describe).joined(separator: "\n"))
                            }
                            Spacer()
                            if let pw = revealed[login.id] {
                                Text(pw).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            }
                            Button { toggleReveal(login) } label: { Label(revealed[login.id] == nil ? "Show Password" : "Hide Password", systemImage: revealed[login.id] == nil ? "eye" : "eye.slash").labelStyle(.iconOnly) }
                                .buttonStyle(.borderless).help(L("Show password"))
                            Button { copy(login) } label: { Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly) }
                                .buttonStyle(.borderless).help(L("Copy password"))
                            Button { store.delete(login) } label: { Label("Delete", systemImage: "trash").labelStyle(.iconOnly) }
                                .buttonStyle(.borderless).help(L("Delete"))
                        }
                    }
                }
            } header: {
                Text("Saved passwords")
            }

            Section {
                HStack {
                    Button("Import from CSV…", action: importCSV)
                    Button("Export to CSV…", action: exportCSV).disabled(store.logins.isEmpty)
                }
            } header: {
                Text("Apple Passwords and other managers")
            } footer: {
                Text("To bring passwords from the Passwords app: in Passwords choose File › Export All Passwords, then import the file here. To send Tacet's passwords to Passwords, export them and choose File › Import Passwords there. CSV files aren't encrypted: delete them afterwards.")
            }

            if !s.neverSaveHosts.isEmpty {
                Section("Never save passwords for") {
                    ForEach(s.neverSaveHosts, id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Button { s.neverSaveHosts.removeAll { $0 == host } } label: { Label("Remove", systemImage: "minus.circle.fill").labelStyle(.iconOnly) }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { store.reload(); managers = ExternalPasswordManager.detect() }
        .onDisappear { revealed = [:] }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func toggleReveal(_ login: SavedLogin) {
        if revealed[login.id] != nil { revealed[login.id] = nil; return }
        store.password(for: login, reason: String(format: L("show your password for %@"), login.host)) { revealed[login.id] = $0 }
    }

    private func copy(_ login: SavedLogin) {
        store.password(for: login, reason: String(format: L("copy your password for %@"), login.host)) { pw in
            guard let pw else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pw, forType: .string)
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let n = store.importCSV(String(decoding: data, as: UTF8.self))
        message = String(format: L("Imported %lld passwords."), n)
    }

    private func exportCSV() {
        store.authenticate(reason: L("export your passwords")) { ok in
            guard ok else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "Tacet Passwords.csv"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? store.exportCSV().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// "Check passwords" and, once checked, how many are breached, reused or weak.
struct PasswordCheckRow: View {
    let issues: [SavedLogin.ID: Set<PasswordStore.Issue>]?
    let checking: Bool
    var empty = false
    let check: () -> Void

    static func describe(_ issue: PasswordStore.Issue) -> String {
        switch issue {
        case .breached: L("Found in a data breach: change it on this site.")
        case .reused: L("Used on more than one site.")
        case .weak: L("Easy to guess.")
        case .unchecked: L("Couldn't be checked against data breaches: check again when you're online.")
        }
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                if let issues {
                    let count = { (i: PasswordStore.Issue) in issues.values.filter { $0.contains(i) }.count }
                    if issues.isEmpty {
                        Label("No problems found", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                    } else {
                        Text(String(format: L("%d in data breaches · %d reused · %d weak"), count(.breached), count(.reused), count(.weak)))
                        if count(.unchecked) > 0 {
                            Text(String(format: L("%d couldn't be checked for breaches. Check again when you're online."), count(.unchecked)))
                                .foregroundStyle(.orange)
                        }
                    }
                } else {
                    Text("Password check")
                }
                Text("Looks for passwords found in data breaches, used on several sites or easy to guess. Only the first 5 characters of each password's SHA-1 hash are sent to Have I Been Pwned; the password never leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if checking { ProgressView().controlSize(.small) }
            Button(issues == nil ? LocalizedStringKey("Check…") : "Check Again") { check() }
                .disabled(checking || empty)
                .help(empty ? L("Save or import passwords first, then check them here.") : "")
        }
    }
}
