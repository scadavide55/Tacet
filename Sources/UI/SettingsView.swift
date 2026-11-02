import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("General", systemImage: "gearshape") }
            AppearancePane().tabItem { Label("Appearance", systemImage: "paintbrush") }
            ShieldPane().tabItem { Label("Shield", systemImage: "shield.lefthalf.filled") }
            PasswordsPane().tabItem { Label("Passwords", systemImage: "key") }
            SearchPane().tabItem { Label("Search", systemImage: "magnifyingglass") }
            SitesPane().tabItem { Label("Sites", systemImage: "globe") }
            AIPane().tabItem { Label("AI", systemImage: "sparkles") }
            AutomationsPane().tabItem { Label("Automations", systemImage: "bolt") }
            ExtensionsPane().tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }
            AdvancedPane().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 680, height: 560)
        .tint(Settings.shared.accent)
    }
}

// MARK: - General

struct GeneralPane: View {
    @Bindable private var s = Settings.shared
    @State private var isDefault = DefaultBrowser.isDefault
    @State private var language: AppLanguage?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isDefault ? LocalizedStringKey("Tacet is your default browser") : "Tacet is not your default browser")
                        Text("Links you open in other apps go to your default browser.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !isDefault {
                        Button("Make Default") {
                            DefaultBrowser.makeDefault { isDefault = DefaultBrowser.isDefault }
                        }
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import from another browser")
                        Text("Bookmarks, history and sign-ins from Safari, Chrome, Firefox, Opera and more.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import…") { openWindow(id: "import") }
                }
            }
            WebAppsSection()
            Section("Updates") {
                UpdateRow()
                Toggle("Check for updates automatically", isOn: $s.checkUpdates)
            }
            Section("Language") {
                Picker("Language", selection: Binding(get: { AppLanguage.current }, set: { lang in
                    lang.apply()
                    language = lang
                })) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
                if language != nil {
                    HStack {
                        Text("Restart Tacet to use the new language.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { AppLanguage.relaunch() }
                    }
                }
            }
            SpacesSettings()
            OpeningRulesSettings()
            Section("Tabs") {
                Toggle("Restore windows and tabs when Tacet opens", isOn: $s.restoreSession)
                Toggle("Open the command bar on every new tab", isOn: $s.paletteOnNewTab)
                Toggle("Show a preview with memory use when you hover over a tab", isOn: $s.tabPreviews)
                Toggle("Pinned tabs open links to other sites in new tabs", isOn: $s.pinnedStayOnSite)
                Picker("Organize tabs", selection: $s.organizeTabs) {
                    Text("Manually").tag(false)
                    Text("Automatically by site").tag(true)
                }
                if s.organizeTabs {
                    Picker("Group when a site has", selection: $s.groupThreshold) {
                        Text("2 tabs").tag(2)
                        Text("3 tabs").tag(3)
                        Text("5 tabs").tag(5)
                    }
                    .onChange(of: s.groupThreshold) { _, _ in BrowserState.groupingChanged() }
                    Text(String(format: L("When %d or more tabs are open from the same site, Tacet groups them, for example into “GitHub”."), s.groupThreshold))
                        .font(.caption).foregroundStyle(.secondary)
                }
                GroupExceptionsRow()
                Picker("Open pages in tabs instead of windows", selection: $s.popupMode) {
                    ForEach(PopupMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Automatically close tabs", selection: $s.autoCloseDays) {
                    Text("Manually").tag(0)
                    Text("After One Day").tag(1)
                    Text("After One Week").tag(7)
                    Text("After One Month").tag(30)
                }
                Toggle("Block videos that play sound automatically", isOn: $s.blockAutoplay)
                Picker("Open new tabs", selection: $s.newTabPosition) {
                    ForEach(NewTabPosition.allCases) { Text($0.label).tag($0) }
                }
                Picker("Hibernate background tabs", selection: $s.hibernateMinutes) {
                    Text("Never").tag(0)
                    Text("After 5 minutes").tag(5)
                    Text("After 15 minutes").tag(15)
                    Text("After 30 minutes").tag(30)
                    Text("After 1 hour").tag(60)
                }
                Text("Hibernated tabs keep their place and history but release memory until you open them again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ProfilesSection()
            Section("Start page") {
                Toggle("Show clock", isOn: $s.showClock)
                Toggle("Show greeting", isOn: $s.showGreeting)
                TextField("Your name", text: $s.userName, prompt: Text("Optional"))
                Toggle("Show favorites", isOn: $s.showFavorites)
            }
            Section {
                HStack {
                    Button("Back Up Everything…") { Backup.backUp() }
                    Button("Restore from Backup…") { Backup.restore() }
                }
                HStack {
                    Button("Export Settings and Plugins…") { SettingsTransfer.export() }
                    Button("Import…") { SettingsTransfer.importFile() }
                }
            } header: {
                Text("Move to another Mac")
            } footer: {
                Text("Back Up Everything makes one encrypted file with all of Tacet: settings and plugins, tabs, Spaces, history, bookmarks, Reading List, highlights, passwords, AI keys and the sites you're signed in to. It's locked with a password you choose. Export Settings and Plugins makes a small file with only those.")
            }
            Section("Downloads") {
                Toggle("Ask where to save each download", isOn: $s.askDownloadLocation)
            }
        }
        .formStyle(.grouped)
        .onAppear { isDefault = DefaultBrowser.isDefault }
    }
}

struct ProfilesSection: View {
    @Bindable private var s = Settings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section {
            ForEach(s.profiles) { p in
                HStack(spacing: 8) {
                    Menu {
                        ForEach(0..<TabGroup.colors.count, id: \.self) { i in
                            Button(GroupHeader.colorNames[i]) { update(p.id) { $0.color = i } }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle.fill").foregroundStyle(p.tint)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Colour")
                    TextField("Name", text: Binding(get: { p.name }, set: { name in update(p.id) { $0.name = name } }))
                        .textFieldStyle(.plain)
                    Spacer()
                    Button("Open Window") { openWindow(id: "profile", value: p.id) }
                    Button { delete(p) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Delete Profile")
                }
            }
            Button("Add Profile") {
                let n = s.profiles.count + 1
                s.profiles.append(Profile(name: String(format: L("Profile %lld"), n), color: n % TabGroup.colors.count))
            }
            if !s.profiles.isEmpty {
                Toggle("Ask which profile to use when Tacet opens", isOn: $s.askProfileAtLaunch)
            }
        } header: {
            Text("Profiles")
        } footer: {
            Text("Each profile keeps its own cookies, sign-ins and site data, so you can be signed in to different accounts at the same time. History, bookmarks, passwords and settings are shared.")
        }
    }

    private func update(_ id: UUID, _ change: (inout Profile) -> Void) {
        guard let i = s.profiles.firstIndex(where: { $0.id == id }) else { return }
        var p = s.profiles[i]
        change(&p)
        s.profiles[i] = p
    }

    private func delete(_ p: Profile) {
        if WindowRegistry.shared.browsers.contains(where: { $0.profileID == p.id }) {
            Dialogs.alert(NSApp.keyWindow, title: L("Close this profile's windows first"),
                          message: L("A profile can be deleted once none of its windows are open.")) {}
            return
        }
        Dialogs.confirm(NSApp.keyWindow, title: String(format: L("Delete “%@”?"), p.name),
                        message: L("Its cookies, sign-ins and site data will be removed. Saved passwords stay in Tacet."),
                        ok: L("Delete")) { ok in
            guard ok else { return }
            s.profiles.removeAll { $0.id == p.id }
            ProfileCleanup.remove(p.id)
        }
    }
}

struct UpdateRow: View {
    private var updates = UpdateChecker.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: L("Tacet %@"), UpdateChecker.currentVersion))
                if let r = updates.available {
                    Text(String(format: L("%@ is available."), r.name)).font(.caption).foregroundStyle(.green)
                } else if let result = updates.lastResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if updates.checking { ProgressView().controlSize(.small) }
            if updates.available != nil {
                Button("Update…") { openWindow(id: "update") }.buttonStyle(.borderedProminent)
            } else {
                Button("Check Now") { updates.check(force: true) }.disabled(updates.checking)
            }
        }
    }
}

enum DefaultBrowser {
    static var isDefault: Bool {
        guard let url = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static func makeDefault(done: @escaping () -> Void) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in
                DispatchQueue.main.async(execute: done)
            }
        }
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @Bindable private var s = Settings.shared
    private let presets = ["#5E5CE6", "#0A84FF", "#30B0C7", "#34C759", "#E8A33D", "#FF6B35", "#FF375F", "#BF5AF2", "#8E8E93"]

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $s.theme) {
                    ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Accent colour") {
                    HStack(spacing: 6) {
                        ForEach(presets, id: \.self) { hex in
                            Circle().fill(Color(hex: hex)).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.primary, lineWidth: s.accentHex.uppercased() == hex ? 2 : 0).padding(-3))
                                .onTapGesture { s.accentHex = hex }
                        }
                        ColorPicker("", selection: s.accentBinding, supportsOpacity: false).labelsHidden()
                    }
                }
                Picker("Window style", selection: $s.chromeStyle) {
                    ForEach(ChromeStyle.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("App icon") {
                AppIconPicker()
            }
            Section("Tabs") {
                TabLayoutPicker().frame(maxWidth: .infinity)
                Toggle("Show colour in tab bar", isOn: $s.siteTint)
                if s.tabLayout == .compact {
                    Toggle("Always show website titles in tabs", isOn: $s.alwaysShowTitles)
                }
                if s.tabLayout == .vertical {
                    Picker("Sidebar position", selection: $s.sidebarSide) {
                        ForEach(SidebarSide.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Put the address bar in the sidebar", isOn: $s.addressInSidebar)
                        .disabled(s.sidebarSide == .right)
                    LabeledContent("Sidebar width") {
                        Slider(value: $s.sidebarWidth, in: 180...420).frame(width: 220)
                    }
                    Toggle("Compact tabs", isOn: $s.compactTabs)
                }
            }
            Section("Page") {
                Toggle("Float the page with rounded corners", isOn: $s.insetContent)
                if s.insetContent {
                    LabeledContent("Corner radius") {
                        Slider(value: $s.cornerRadius, in: 0...20, step: 1).frame(width: 220)
                    }
                }
                Toggle("Show the full address", isOn: $s.showFullURL)
                Toggle("Show link addresses on hover", isOn: $s.statusBar)
                Toggle("Scroll up at the top of a page to reload it", isOn: $s.pullToRefresh)
            }
            Section("Start page background") {
                BackgroundPicker()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shield

struct ShieldPane: View {
    @Bindable private var s = Settings.shared
    private var blocker = ContentBlocker.shared
    @State private var newHost = ""
    @State private var showClear = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $s.adBlock) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Block ads and trackers")
                        Text("\(blocker.ruleCount.formatted()) rules active. Toggle anytime with ⇧⌘B.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Hide cookie consent banners", isOn: $s.hideCookieBanners).disabled(!s.adBlock)
                Toggle(isOn: $s.rejectCookies) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reject optional cookies for me")
                        Text("Presses “Reject all” on cookie banners that offer it, so sites remember your choice.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!s.adBlock || !s.hideCookieBanners)
                Toggle(isOn: $s.fingerprintProtection) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Protect against fingerprinting")
                        Text("Changes canvas, WebGL and audio readings slightly for each site, so they can't be used to recognise your Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!s.adBlock)
                Toggle("Skip YouTube ads", isOn: $s.youtubeAds).disabled(!s.adBlock)
            }
            Section {
                Toggle("EasyList (ads)", isOn: $s.easyList).disabled(!s.adBlock)
                Toggle("EasyPrivacy (trackers)", isOn: $s.easyPrivacy).disabled(!s.adBlock)
                Toggle("AdGuard Base (ads, another list)", isOn: $s.adGuardBase).disabled(!s.adBlock)
                Toggle("Fanboy Annoyances (pop-ups, social widgets, newsletters)", isOn: $s.fanboyAnnoyance).disabled(!s.adBlock)
                Toggle(isOn: $s.cnameTrackers) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hidden trackers (AdGuard)")
                        Text("Trackers disguised as part of the site, like metrics.example.com. A long list: it takes a minute to prepare.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!s.adBlock)
                HStack {
                    if blocker.updating {
                        ProgressView().controlSize(.small)
                        Text(blocker.status).foregroundStyle(.secondary)
                    } else if !blocker.status.isEmpty {
                        Text(blocker.status).foregroundStyle(.orange)
                    } else if let date = blocker.lastUpdated {
                        Text("\(blocker.filterCount.formatted()) rules · updated \(date.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Lists are downloaded from easylist.to and refreshed weekly.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Update Now") { blocker.updateFilterLists() }
                        .disabled(blocker.updating || !ContentBlocker.anyListEnabled)
                }
                .font(.caption)
            } header: {
                Text("Filter lists")
            } footer: {
                Text("The built-in list works offline. Filter lists add tens of thousands of community-maintained rules.")
            }
            Section("Privacy") {
                Toggle("Block third-party cookies", isOn: $s.blockThirdPartyCookies)
                Toggle("Remove tracking parameters from links", isOn: $s.stripTracking)
                Toggle("Upgrade connections to HTTPS", isOn: $s.httpsUpgrade)
                Toggle(isOn: $s.httpsOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HTTPS-only mode")
                        Text("Sites that don't support HTTPS won't open until you confirm.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Confirm before downloading apps, installers and scripts", isOn: $s.confirmDangerousDownloads)
                Toggle("Lock private windows with Touch ID when Tacet is in the background", isOn: $s.lockPrivateWindows)
                Toggle("Tell sites not to sell or share my data (Global Privacy Control)", isOn: $s.gpc)
                Toggle("Clear cookies, cache and history when Tacet quits", isOn: $s.clearOnQuit)
                Toggle(isOn: $s.recoverDrafts) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep unsent text to put it back")
                        Text("Long text you write in a page is kept on this Mac until it's sent, so a reload or a closed tab doesn't lose it. Never passwords, card numbers or private windows; nothing older than a week.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Clear Browsing Data…") { showClear = true }
            }
            PageTextSettings()
            Section("Sites where Shield is off") {
                if s.allowlist.isEmpty {
                    Text("None. Turn Shield off for a site from the shield button in the toolbar.").foregroundStyle(.secondary)
                }
                ForEach(s.allowlist, id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        Button { s.setAllowlisted(host, false) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("example.com", text: $newHost).onSubmit(addHost)
                    Button("Add", action: addHost).disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showClear) { ClearDataSheet() }
    }

    private func addHost() {
        let raw = newHost.trimmingCharacters(in: .whitespaces).lowercased()
        let host = URL(string: raw.contains("://") ? raw : "https://" + raw)?.host ?? raw
        guard !host.isEmpty else { return }
        s.setAllowlisted(host, true)
        newHost = ""
    }
}

struct ClearDataSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var range = DataCleaner.Range.hour
    @State private var history = true
    @State private var cookies = true
    @State private var cache = true
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clear Browsing Data").font(.title3.weight(.semibold))
            Picker("Time range", selection: $range) {
                ForEach(DataCleaner.Range.allCases) { Text($0.label).tag($0) }
            }
            Toggle("History", isOn: $history)
            Toggle("Cookies and site data (signs you out of most sites)", isOn: $cookies)
            Toggle("Cached images and files", isOn: $cache)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Clear") {
                    working = true
                    DataCleaner.clear(range: range, history: history, cookies: cookies, cache: cache) {
                        working = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || !(history || cookies || cache))
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Search

struct SearchPane: View {
    @Bindable private var s = Settings.shared
    @State private var keyword = ""
    @State private var name = ""
    @State private var template = ""

    var body: some View {
        Form {
            Section("Search engine") {
                Picker("Search with", selection: $s.engine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                }
                if s.engine == .custom {
                    TextField("Search URL", text: $s.customSearch, prompt: Text("https://example.com/search?q=%s"))
                    Text("Use %s where the search terms go.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Show search suggestions", isOn: $s.suggestions)
                    .disabled(s.engine.suggestTemplate == nil)
                Text("Suggestions send what you type to \(s.engine.name). They're never fetched in private windows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(s.shortcuts) { sc in
                    HStack(spacing: 10) {
                        Text(sc.keyword).font(.system(.body, design: .monospaced)).lineLimit(1).frame(width: 70, alignment: .leading)
                        Text(sc.name).lineLimit(1).frame(width: 110, alignment: .leading)
                        Text(sc.template).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { s.shortcuts.removeAll { $0.id == sc.id } } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                // The same columns as the rows above. In a grouped form a field's title becomes a label beside it,
                // so the hints go inside the fields as prompts instead.
                HStack(spacing: 10) {
                    TextField("Keyword", text: $keyword, prompt: Text("Keyword")).labelsHidden().frame(width: 70)
                    TextField("Name", text: $name, prompt: Text("Name")).labelsHidden().frame(width: 110)
                    TextField("URL with %s", text: $template, prompt: Text("URL with %s")).labelsHidden()
                    Button("Add") {
                        s.shortcuts.append(SearchShortcut(keyword: keyword.trimmingCharacters(in: .whitespaces),
                                                          name: name.isEmpty ? keyword : name, template: template))
                        keyword = ""; name = ""; template = ""
                    }
                    .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty || !template.contains("%s"))
                }
            } header: {
                Text("Search shortcuts")
            } footer: {
                Text("Type a keyword, a space and your search in the command bar. For example: yt lofi beats")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sites

struct SitesPane: View {
    @Bindable private var s = Settings.shared
    @State private var editing: EditTarget?

    struct EditTarget: Identifiable {
        let id = UUID()
        let host: String?
    }

    /// "Dark · 3 hidden · CSS"
    static func summary(_ style: SiteStyle) -> String {
        var parts: [String] = []
        if style.theme == .dark { parts.append(L("Dark")) }
        if style.font != .site { parts.append(L("Font")) }
        if style.width != .site { parts.append(L("Width")) }
        if style.hideFloating { parts.append(L("No pop-ups")) }
        if style.hideImages { parts.append(L("No images")) }
        if style.reduceMotion { parts.append(L("No animations")) }
        if !style.hidden.isEmpty { parts.append(String(format: L("%d hidden"), style.hidden.count)) }
        if !style.css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("CSS") }
        if !style.js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("JavaScript") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Form {
            Section {
                Toggle("Force dark pages (experimental)", isOn: $s.forceDark)
                Picker("Default zoom", selection: $s.defaultZoom) {
                    ForEach(Tab.zoomSteps, id: \.self) { Text("\(Int((($0) * 100).rounded()))%").tag($0) }
                }
            }
            Section {
                ForEach(s.siteStyles) { style in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { style.enabled },
                            set: { on in var copy = style; copy.enabled = on; s.saveSiteStyle(copy) }
                        )).labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(style.host)
                            Text(SitesPane.summary(style)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Edit…") { editing = EditTarget(host: style.host) }
                        Button { s.siteStyles.removeAll { $0.id == style.id } } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Remove")
                    }
                }
                Button("Customize a Site…") { editing = EditTarget(host: nil) }
            } header: {
                Text("Customized sites")
            } footer: {
                Text("Change a site's colours, font and width, hide parts of it, or add your own CSS and JavaScript. On any page, choose Customize This Site from the ⋯ menu or the command bar.")
            }
            Section("Camera and microphone") {
                if s.mediaPermissions.isEmpty {
                    Text("Sites you allow or block from using your camera or microphone are remembered here.").foregroundStyle(.secondary)
                }
                ForEach(s.mediaPermissions.sorted { $0.key < $1.key }, id: \.key) { key, allowed in
                    if let p = MediaPermission.parse(key) {
                        HStack {
                            Text(p.host)
                            Text(p.kind.label).foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: Binding(get: { allowed }, set: { s.mediaPermissions[key] = $0 })) {
                                Text("Allow").tag(true)
                                Text("Block").tag(false)
                            }
                            .labelsHidden()
                            .fixedSize()
                            Button { s.mediaPermissions[key] = nil } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("Forget")
                        }
                    }
                }
            }
            Section("Zoom levels") {
                if s.siteZoom.isEmpty {
                    Text("Sites you zoom in or out are remembered here.").foregroundStyle(.secondary)
                }
                ForEach(s.siteZoom.sorted { $0.key < $1.key }, id: \.key) { host, zoom in
                    HStack {
                        Text(host)
                        Spacer()
                        Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                        Button { s.siteZoom[host] = nil } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { target in
            SiteCustomizer(host: target.host)
        }
    }
}

// MARK: - Advanced

struct AdvancedPane: View {
    @Bindable private var s = Settings.shared

    var body: some View {
        Form {
            Section("Web content") {
                Toggle("Enable JavaScript", isOn: $s.javaScript)
                Picker("User agent", selection: $s.uaMode) {
                    ForEach(UserAgentMode.allCases) { Text($0.label).tag($0) }
                }
                if s.uaMode == .custom {
                    TextField("User agent", text: $s.customUA, prompt: Text("Mozilla/5.0 …"))
                }
                Text("Tacet identifies as Safari \(UserAgent.safariVersion) so sites serve their full experience.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Developer") {
                Toggle("Enable Web Inspector", isOn: $s.developer)
                Text("Right-click a page and choose Inspect Element.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Data folder") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.support]) }
                }
            }
            Section {
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                }
            }
        }
        .formStyle(.grouped)
    }
}


/// Sites Tacet never groups by site, with a field to add one.
struct GroupExceptionsRow: View {
    @Bindable private var s = Settings.shared
    @State private var adding = ""

    var body: some View {
        LabeledContent("Never group these sites") {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(s.groupExceptions, id: \.self) { site in
                    HStack(spacing: 6) {
                        Text(site)
                        Button {
                            s.setGroupException(site, false)
                            BrowserState.groupingChanged()
                        } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                            .help("Remove")
                    }
                }
                TextField("", text: $adding, prompt: Text("example.com"))
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit(add)
            }
        }
    }

    private func add() {
        let raw = adding.trimmingCharacters(in: .whitespaces).lowercased()
        let host = URL(string: raw.contains("://") ? raw : "https://" + raw)?.host ?? raw
        guard host.contains(".") else { return }
        s.setGroupException(host, true)
        adding = ""
        BrowserState.groupingChanged()
    }
}
