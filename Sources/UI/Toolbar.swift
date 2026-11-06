import SwiftUI

struct Toolbar: View {
    let trafficSpace: Bool
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared

    var body: some View {
        HStack(spacing: 4) {
            if trafficSpace && !b.isFullScreen { Spacer().frame(width: 72) }
            if s.tabLayout == .vertical { SidebarToggle() }
            if let tab = b.current { ToolbarContent(tab: tab) }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(WindowDragArea())
    }
}

struct ToolbarContent: View {
    var tab: Tab
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared

    var body: some View {
        let horizontal = s.tabLayout != .vertical
        HStack(spacing: 4) {
            NavButtons(tab: tab)
            if horizontal { Spacer(minLength: 8) }
            AddressPill(tab: tab).frame(maxWidth: horizontal ? 720 : .infinity)
            if horizontal { Spacer(minLength: 8) }
            if horizontal, let p = b.profile { ProfileBadge(profile: p, compact: true).fixedSize() }
            if horizontal { SpaceMenuButton() }
            ExtensionButtons(tab: tab)
            ExtensionsMenuButton(tab: tab)
            ShieldButton(tab: tab)
            DownloadsButton()
            AssistantButton()
            PageMenu(tab: tab)
        }
    }
}

// MARK: - Address

struct AddressPill: View {
    var tab: Tab
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared
    private var bookmarks = Bookmarks.shared
    @State private var hover = false
    @State private var showInfo = false

    private var shownURL: URL? { tab.failedURL ?? tab.url }

    private var text: String {
        guard let u = shownURL else { return L("Search or enter address") }
        if tab.isReader { return L("Reader") + " · " + InputResolver.displayHost(u) }
        return s.showFullURL ? u.absoluteString : InputResolver.displayHost(u)
    }

    private var lock: (String, Color) {
        guard let u = shownURL else { return ("magnifyingglass", .secondary) }
        if tab.failedURL != nil { return ("exclamationmark.triangle.fill", .orange) }
        if InputResolver.isInternational(u) { return ("character.textbox", .orange) }
        switch u.scheme {
        case "https": return tab.isSecure ? ("lock.fill", .secondary) : ("lock.trianglebadge.exclamationmark", .orange)
        case "http": return ("exclamationmark.triangle", .orange)
        case "file": return ("doc", .secondary)
        default: return ("globe", .secondary)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { showInfo.toggle() } label: {
                Image(systemName: lock.0).font(.system(size: 11, weight: .medium)).foregroundStyle(lock.1).frame(width: 16)
            }
            .buttonStyle(.plain)
            .disabled(shownURL == nil)
            .popover(isPresented: $showInfo, arrowEdge: .bottom) { SiteInfoPopover(tab: tab) }
            .help("Site information")
            .accessibilityLabel("Site information")

            Text(text)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(shownURL == nil ? .secondary : .primary)
                .contextMenu {
                    if shownURL != nil { Button("Site Information…") { showInfo = true } }
                }
            Spacer(minLength: 4)

            if tab.url != nil && abs(tab.zoom - 1) > 0.01 {
                Button { tab.zoom(0) } label: {
                    Text("\(Int((tab.zoom * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("Reset zoom"))
            }

            if tab.url != nil && (hover || tab.isReader) {
                Button { tab.toggleReader() } label: {
                    Image(systemName: tab.isReader ? "doc.plaintext.fill" : "doc.plaintext").font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab.isReader ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help("Reader (⇧⌘R)")
                .accessibilityLabel("Reader")
            }
            if tab.url != nil && (hover || bookmarks.contains(tab.url)) {
                Button { bookmarks.toggle(url: tab.url, title: tab.title) } label: {
                    Image(systemName: bookmarks.contains(tab.url) ? "star.fill" : "star").font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(bookmarks.contains(tab.url) ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                .help("Bookmark (⌘D)")
                .accessibilityLabel("Bookmark")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.085 : 0.055)))
        .overlay(alignment: .bottom) {
            if tab.isLoading { LoadingLine(load: tab.load).padding(.horizontal, 6) }
        }
        .contentShape(Rectangle())
        .onTapGesture { b.showPalette(shownURL?.absoluteString) }
        .onHover { hover = $0 }
        .onChange(of: b.showSiteInfo) { _, show in
            guard show, tab === b.current else { return }
            b.showSiteInfo = false
            // After the command bar has closed, or the popover has nothing to hang from.
            if shownURL != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showInfo = true } }
        }
        .help(shownURL?.absoluteString ?? L("Search or enter address (⌘L)"))
    }
}

/// The progress line of a loading page; it watches only the progress, not the whole tab.
struct LoadingLine: View {
    var load: LoadProgress
    var body: some View { ProgressLine(progress: load.value) }
}

struct ProgressLine: View {
    let progress: Double

    var body: some View {
        GeometryReader { g in
            Capsule()
                .fill(.tint)
                .frame(width: max(8, g.size.width * progress), height: 2)
                .animation(.easeOut(duration: 0.25), value: progress)
        }
        .frame(height: 2)
    }
}

// MARK: - Shield

struct ShieldButton: View {
    var tab: Tab
    @Bindable var s = Settings.shared
    @State private var show = false

    var body: some View {
        let on = tab.shieldsUp
        IconButton(systemName: on ? "shield.lefthalf.filled" : "shield.slash",
                   help: on ? "Tacet Shield is on" : "Tacet Shield is off for this page",
                   tint: on ? s.accent : nil) { show.toggle() }
            .popover(isPresented: $show, arrowEdge: .bottom) { ShieldPopover(tab: tab) }
    }
}

struct ShieldPopover: View {
    var tab: Tab
    @Bindable private var s = Settings.shared
    private var blocker = ContentBlocker.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: tab.shieldsUp ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.system(size: 24))
                    .foregroundStyle(tab.shieldsUp ? s.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tacet Shield").font(.headline)
                    Text(tab.host.map { InputResolver.displayHost(URL(string: "https://" + $0)) } ?? L("No site loaded"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if tab.shieldsUp && tab.url != nil { BlockedOnPage(tab: tab) }
            if let host = tab.host {
                Toggle("Protection on this site", isOn: Binding(
                    get: { !s.isShieldOff(host) },
                    set: { s.setShield(host, on: $0) }))
                    .disabled(!s.adBlock)
                if tab.shieldsUp && tab.url != nil {
                    // Off only until Tacet quits; the banner on the page then asks whether to keep it off.
                    Button("Site not working?") {
                        tab.askKeepShieldOff = true
                        ShieldTrial.shared.start(host)
                        dismiss()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Turns Tacet Shield off on this site for now and reloads the page")
                }
            }
            Divider()
            Toggle("Block ads and trackers", isOn: $s.adBlock)
            Toggle("Hide cookie banners", isOn: $s.hideCookieBanners).disabled(!s.adBlock)
            Toggle("Skip YouTube ads", isOn: $s.youtubeAds).disabled(!s.adBlock)
            Toggle("Protect against fingerprinting", isOn: $s.fingerprintProtection).disabled(!s.adBlock)
            Toggle("Block third-party cookies", isOn: $s.blockThirdPartyCookies)
            Toggle("Remove tracking from links", isOn: $s.stripTracking)
            HStack {
                Text(s.adBlock ? LocalizedStringKey("\(blocker.ruleCount.formatted()) rules active") : "Blocking is off")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Text("Settings…") }.controlSize(.small)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(16)
        .frame(width: 300)
    }
}

/// "12 blocked on this page", and from which sites.
struct BlockedOnPage: View {
    var tab: Tab
    @State private var expanded = false

    var body: some View {
        let count = tab.blockedCount
        VStack(alignment: .leading, spacing: 6) {
            Button { if count > 0 { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("\(count)").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 0) {
                        Text(count == 1 ? LocalizedStringKey("ad or tracker blocked on this page") : "ads and trackers blocked on this page")
                            .font(.system(size: 12, weight: .medium))
                        if count > 0 {
                            Text(String(format: L("from %d sites"), tab.blockedHere.count)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if count > 0 { Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            let stats = ShieldStats.shared
            HStack(spacing: 14) {
                if let site = tab.host.map(PasswordStore.site) {
                    Text(String(format: L("%@ on this site"), (stats.bySite[site] ?? 0).formatted()))
                }
                Text(String(format: L("%@ this session"), stats.session.formatted()))
            }
            .font(.caption).foregroundStyle(.secondary)
            if expanded {
                ForEach(tab.blockedHere.sorted { $0.value > $1.value }.prefix(12), id: \.key) { site, n in
                    HStack {
                        Text(site).font(.system(size: 11.5)).lineLimit(1)
                        Spacer()
                        Text("\(n)").font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Site information

struct SiteInfoPopover: View {
    var tab: Tab
    @Environment(BrowserState.self) var b
    @State private var cleared = false

    var body: some View {
        let url = tab.failedURL ?? tab.url
        let secure = url?.scheme == "https" && tab.isSecure
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: secure ? "lock.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(secure ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(secure ? LocalizedStringKey("Connection is secure") : "Connection is not secure").font(.headline)
                    Text(InputResolver.displayHost(url)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if InputResolver.isInternational(url) {
                Label("This address uses letters from other alphabets, which can be made to look like a familiar site. Check that it's the site you meant to visit.", systemImage: "character.textbox")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if secure, let cert = tab.certificateSummary {
                Label(cert, systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary)
            } else if url?.scheme == "http" {
                Text("Anything you send to this site, like passwords or card numbers, could be read by others.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("Zoom")
                Spacer()
                Button { tab.zoom(-1) } label: { Label("Zoom Out", systemImage: "minus").labelStyle(.iconOnly) }
                Text("\(Int((tab.zoom * 100).rounded()))%").monospacedDigit().frame(width: 44)
                Button { tab.zoom(1) } label: { Label("Zoom In", systemImage: "plus").labelStyle(.iconOnly) }
                Button("Reset") { tab.zoom(0) }
            }
            .controlSize(.small)
            if let host = tab.host {
                SitePermissions(tab: tab, host: host)
                Divider()
                Button(cleared ? LocalizedStringKey("Site data cleared") : "Clear Data for This Site…") {
                    Dialogs.confirm(b.window, title: String(format: L("Clear data for %@?"), InputResolver.displayHost(url)),
                                    message: L("You'll be signed out of this site and its saved preferences will be removed."),
                                    ok: L("Clear")) { ok in
                        guard ok else { return }
                        DataCleaner.clearSite(host, store: b.dataStore) {
                            cleared = true
                            tab.reload()
                        }
                    }
                }
                .disabled(cleared)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// What the site may do, from the same settings as Settings › Sites and Tacet Shield: changing something here
/// changes it there.
struct SitePermissions: View {
    var tab: Tab
    let host: String
    @Bindable private var s = Settings.shared
    /// A private tab's choices aren't observed: this redraws after one changes.
    @State private var revision = 0

    /// Camera and microphone choices for this site; a private window's stay in the tab.
    private var media: [(key: String, kind: MediaPermission.Kind, allowed: Bool)] {
        let stored = tab.isPrivate ? tab.mediaPermissions : s.mediaPermissions
        return stored.compactMap { key, allowed in
            guard let p = MediaPermission.parse(key), p.host == host.lowercased() else { return nil }
            return (key, p.kind, allowed)
        }
        .sorted { $0.key < $1.key }
    }

    private func setMedia(_ key: String, _ allowed: Bool?) {
        if tab.isPrivate { tab.mediaPermissions[key] = allowed } else { s.mediaPermissions[key] = allowed }
        revision += 1
    }

    var body: some View {
        let site = PasswordStore.site(host)
        let _ = revision
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(media, id: \.key) { item in
                HStack {
                    Text(item.kind.label.prefix(1).uppercased() + item.kind.label.dropFirst())
                    Spacer()
                    Picker("", selection: Binding(get: { item.allowed }, set: { setMedia(item.key, $0) })) {
                        Text("Allow").tag(true)
                        Text("Block").tag(false)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button { setMedia(item.key, nil) } label: { Label("Forget", systemImage: "minus.circle.fill").labelStyle(.iconOnly) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Forget")
                }
            }
            if media.isEmpty {
                Text("This site hasn't asked for your camera or microphone.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Pop-ups without a click", isOn: Binding(
                get: { s.popupSites.contains(site) },
                set: { on in
                    if on { if !s.popupSites.contains(site) { s.popupSites.append(site) } } else { s.popupSites.removeAll { $0 == site } }
                }))
                .help("Pop-ups a click opens are always allowed")
            Toggle("Tacet Shield on this site", isOn: Binding(get: { !s.isShieldOff(host) }, set: { s.setShield(host, on: $0) }))
                .disabled(!s.adBlock)
            Text(s.adBlock && tab.shieldsUp
                 ? String(format: L("%d ads and trackers blocked on this page"), tab.blockedCount)
                 : L(s.adBlock ? "Nothing is blocked on this site" : "Blocking is off"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: - Downloads

struct DownloadsButton: View {
    private var dm = DownloadManager.shared
    @State private var show = false

    var body: some View {
        if !dm.items.isEmpty {
            IconButton(systemName: dm.active.isEmpty ? "arrow.down.circle" : "arrow.down.circle.dotted",
                       help: "Downloads (⌥⌘L)", tint: dm.unseen ? .accentColor : nil) {
                show.toggle()
                dm.unseen = false
            }
            .overlay {
                if !dm.active.isEmpty {
                    Circle().trim(from: 0, to: dm.overallFraction)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 20, height: 20)
                        .allowsHitTesting(false)
                }
            }
            .popover(isPresented: $show, arrowEdge: .bottom) {
                DownloadsList().frame(width: 400, height: 340)
            }
        }
    }
}

struct DownloadsList: View {
    /// In the Library, the list can be searched.
    var searchable = false
    private var dm = DownloadManager.shared
    @State private var search = ""
    /// The row the arrow keys move and the space bar previews.
    @State private var selection: UUID?
    @FocusState private var focused: Bool

    init(searchable: Bool = false) { self.searchable = searchable }

    private func move(_ step: Int) {
        let list = shown
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == selection }.map { $0 + step } ?? (step > 0 ? 0 : list.count - 1)
        selection = list[min(max(i, 0), list.count - 1)].id
        QuickLook.shared.follow(selectedFile)
    }

    private var selectedFile: URL? {
        guard let item = shown.first(where: { $0.id == selection }), item.state == .finished else { return nil }
        return item.destination
    }

    private var shown: [DownloadItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return dm.items }
        return dm.items.filter { $0.filename.localizedCaseInsensitiveContains(q) || ($0.source?.host?.localizedCaseInsensitiveContains(q) ?? false) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Downloads").font(.headline)
                if dm.totalSpeed > 0 {
                    Text(DownloadItem.speedText(dm.totalSpeed)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                if !dm.active.isEmpty {
                    Button("Pause All") { dm.pauseAll() }
                } else if dm.items.contains(where: { $0.state == .paused }) {
                    Button("Resume All") { dm.resumeAll() }
                }
                Button("Clear") { dm.clearFinished() }.disabled(dm.items.allSatisfy { $0.state == .active || $0.state == .paused })
            }
            .padding(12)
            Divider()
            if dm.items.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle").frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(shown) { item in
                                DownloadRow(item: item, selected: item.id == selection) {
                                    selection = item.id
                                    focused = true
                                    QuickLook.shared.follow(selectedFile)
                                }
                                .id(item.id)
                            }
                        }
                    }
                    .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
                }
                // ↑ and ↓ choose a download, the space bar shows it in Quick Look, Return opens it.
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.space) {
                    guard let file = selectedFile else { return .ignored }
                    QuickLook.shared.toggle(file)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard let item = shown.first(where: { $0.id == selection }), item.state == .finished else { return .ignored }
                    dm.open(item)
                    return .handled
                }
                .onAppear { focused = true }
            }
        }
        // In the Library, searched from the toolbar like History and Bookmarks.
        .modifier(DownloadSearch(on: searchable, text: $search))
    }
}

private struct DownloadSearch: ViewModifier {
    let on: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if on { content.searchable(text: $text, placement: .toolbar, prompt: Text("Search Downloads")) } else { content }
    }
}

struct DownloadRow: View {
    var item: DownloadItem
    var selected = false
    var select: (() -> Void)?
    private var dm: DownloadManager { .shared }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon).resizable().frame(width: 32, height: 32)
                .opacity(item.state == .finished || item.state == .active ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).lineLimit(1).truncationMode(.middle)
                if item.state == .active || item.state == .paused {
                    ProgressView(value: item.fraction).controlSize(.small)
                        .tint(item.state == .paused ? .secondary : .accentColor)
                }
                Text(item.statusText).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 2) {
                switch item.state {
                case .active:
                    IconButton(systemName: "pause.circle.fill", help: "Pause") { dm.pause(item) }
                    IconButton(systemName: "xmark.circle.fill", help: "Cancel") { dm.cancel(item) }
                case .paused:
                    IconButton(systemName: "play.circle.fill", help: "Resume") { dm.resume(item) }
                    IconButton(systemName: "xmark.circle.fill", help: "Cancel") { dm.cancel(item) }
                case .finished:
                    IconButton(systemName: "magnifyingglass", help: "Show in Finder") { dm.reveal(item) }
                default:
                    if item.canResume {
                        IconButton(systemName: "play.circle.fill", help: "Resume") { dm.resume(item) }
                    } else if item.canRetry {
                        IconButton(systemName: "arrow.clockwise.circle.fill", help: "Download Again") { dm.retry(item) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.16) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { dm.open(item) }
        .simultaneousGesture(TapGesture().onEnded { select?() })
        .onDrag {
            // Drag a finished file out to Finder or another app.
            guard item.state == .finished, let url = item.destination else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Open") { dm.open(item) }.disabled(item.state != .finished)
            if item.state == .finished, let file = item.destination {
                // The apps are looked up only when this is chosen, not each time the list redraws.
                Button("Open With…") { dm.openWith(file) }
                // The file itself, to paste in Finder, Mail or a chat.
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([file as NSURL])
                }
            }
            Button("Show in Finder") { dm.reveal(item) }.disabled(item.destination == nil)
            if item.state == .finished, let file = item.destination {
                Button("Quick Look") { QuickLook.shared.toggle(file) }
            }
            Divider()
            if item.state == .active { Button("Pause") { dm.pause(item) } }
            if item.canResume { Button("Resume") { dm.resume(item) } }
            if item.state == .active || item.state == .paused { Button("Cancel") { dm.cancel(item) } }
            if item.canRetry && item.state != .active { Button("Download Again") { dm.retry(item) } }
            if let src = item.source {
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(src.absoluteString, forType: .string)
                }
            }
            Divider()
            Button("Remove from List") { dm.remove(item) }
            if item.state == .finished, item.destination != nil {
                Button("Move to Trash") { dm.trash(item) }
            }
        }
    }
}

// MARK: - Page menu

struct PageMenu: View {
    var tab: Tab
    @Environment(BrowserState.self) var b
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            Button(tab.isReader ? LocalizedStringKey("Exit Reader") : "Reader") { tab.toggleReader() }.disabled(tab.url == nil)
            if !b.isPrivate {
                Button("Save for Offline") { tab.saveForOffline() }.disabled(tab.url == nil)
            }
            Button("Find on Page…") { b.showFind() }.disabled(tab.url == nil)
            if tab.translatedFrom != nil {
                Button("Show Original") { tab.showOriginal() }
            } else {
                Button("Translate Page") { tab.translatePage() }.disabled(tab.url == nil)
            }
            Button(tab.readingAloud ? LocalizedStringKey("Stop Reading Aloud") : "Read Aloud") { ReadAloud.shared.toggle(tab) }.disabled(tab.url == nil)
            Button("Focus Mode") { b.focusMode = true }
            Menu("Zoom") {
                Button("Zoom In") { tab.zoom(1) }
                Button("Zoom Out") { tab.zoom(-1) }
                Button("Actual Size") { tab.zoom(0) }
            }
            Divider()
            if let url = tab.url {
                ShareLink(item: url)
                Button("Copy Link") { copy(url) }
                Button("Copy Link Without Tracking") { copy(URLCleaner.clean(url) ?? url) }
            }
            Button("Print…") { tab.printPage() }.disabled(tab.url == nil)
            Button("Export as PDF…") { tab.exportPDF() }.disabled(tab.url == nil)
            Button("Customize This Site…") { b.customizingSite = true }.disabled(tab.host == nil || tab.isReader)
            Button("Install as App…") { b.showInstallApp = true }.disabled(tab.url == nil || WebApp.isActive)
            Menu("Take Screenshot") {
                Button("Visible Part of Page") { tab.screenshot() }
                Button("Whole Page") { tab.screenshotFullPage() }
                Button("Element…") { tab.startPickingScreenshot() }.disabled(tab.isReader)
            }
            .disabled(tab.url == nil)
            if Settings.shared.developer {
                Menu("Develop") { DevelopMenuItems(b: b) }
            }
            Divider()
            Button(b.splitTab == nil ? LocalizedStringKey("Split View with New Tab") : "Close Split View") {
                b.splitTab == nil ? b.splitWithNewTab() : b.closeSplit()
            }
            Button(tab.isPinned ? LocalizedStringKey("Unpin Tab") : "Pin Tab") { b.togglePin(tab) }
            Button(tab.isMuted ? LocalizedStringKey("Unmute Tab") : "Mute Tab") { tab.setMuted(!tab.isMuted) }
            Divider()
            Button("History and Bookmarks") {
                LibraryView.requestedSection = .history
                openWindow(id: "library")
            }
            Button("Reading List") {
                LibraryView.requestedSection = .readingList
                openWindow(id: "library")
            }
            SettingsLink { Text("Settings…") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 26)
        .foregroundStyle(.secondary)
        .help("More")
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}
