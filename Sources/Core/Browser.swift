import LocalAuthentication
import SwiftUI
import WebKit

/// State for one browser window: its tabs, selection, split view and overlays.
@Observable
final class BrowserState {
    let isPrivate: Bool
    let dataStore: WKWebsiteDataStore
    /// The profile whose cookies and site data this window uses; nil for the main one.
    let profileID: UUID?
    var profile: Profile? { profileID.flatMap { id in Settings.shared.profiles.first { $0.id == id } } }

    var tabs: [Tab] = [] {
        didSet {
            sessionChanged()
            if !isPrivate { ExtensionEvents.tabsChanged(from: oldValue, to: tabs) }
        }
    }
    var groups: [TabGroup] = []
    /// A tab whose page should be translated; PageTranslationHost picks it up.
    var translateRequest: UUID?
    /// The window fills its own Space, where macOS hides the traffic lights, so no room is kept for them.
    var isFullScreen = false
    @ObservationIgnored private var fullScreenObservers: [NSObjectProtocol] = []
    /// Only the page: no sidebar, toolbar or tabs, until Focus Mode is turned off.
    var focusMode = false
    /// Words typed in the sidebar's tab search; only matching tabs show while it isn't empty.
    var tabFilter = ""
    var tabFilterVisible = false
    /// Tabs picked with ⌘-click or ⇧-click, to move, group or close together.
    var marked: Set<UUID> = []
    /// Where ⇧-click ranges start.
    @ObservationIgnored var markAnchor: UUID?
    @ObservationIgnored private var popups: [PopupWindow] = []
    var selectedID: UUID? {
        didSet {
            sessionChanged()
            // A preview belongs to the page it was opened over.
            if selectedID != oldValue, preview != nil { closePreview() }
            if selectedID != oldValue, let t = current {
                ExtensionEvents.activated(t, previous: oldValue.flatMap { id in tabs.first { $0.id == id } })
                // A dialog the page showed while in the background, once its page is in the window.
                if t.dialogWaiting { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { t.showWaitingDialog() } }
            }
        }
    }
    var splitID: UUID? { didSet { sessionChanged() } }
    /// The Space this window shows; nil until Spaces are used.
    var spaceID: UUID? { didSet { sessionChanged() } }
    var space: Space? { Spaces.shared.space(spaceID) }
    /// A link open over the page; see `openPreview`.
    var preview: Tab?
    var sidebarVisible: Bool {
        didSet { if !isPrivate { Settings.shared.sidebarVisible = sidebarVisible } }
    }
    var peekSidebar = false
    var paletteVisible = false
    var findVisible = false
    var showOnboarding = false
    var locked = false
    var showInstallApp = false
    /// The Customize Site panel for the current tab's site.
    var customizingSite = false
    /// Asks the address bar to open Site Information.
    var showSiteInfo = false
    /// Asks the sidebar to take the keyboard, for moving through the tabs with the arrow keys.
    var focusTabList = false
    var assistantVisible = false { didSet { if !assistantVisible { assistantExpanded = false } } }
    /// The assistant fills the window, as a chat app.
    var assistantExpanded = false
    var showAssistantIntro = false
    /// "Welcome to Tacet <version>": what's new, once after an update.
    var showWhatsNew = false
    @ObservationIgnored private(set) lazy var assistant = AssistantChat(browser: self)
    /// The answer shown in the command bar when you ask Tacet Assistant from there.
    @ObservationIgnored private(set) lazy var quickAnswer = AssistantChat(browser: self, quick: true)
    @ObservationIgnored var palettePrefill = ""
    @ObservationIgnored weak var window: NSWindow?

    /// Closed tabs to reopen, newest last; tabs closed together (other tabs, a group) share a batch and come back together.
    private(set) var closedTabs: [(snapshot: TabSnapshot, index: Int, batch: Int)] = []
    /// Several tabs just closed at once: the toast that offers to bring them back, until it times out.
    private(set) var closedToast: (count: Int, batch: Int)?
    @ObservationIgnored private var toastTimer: DispatchWorkItem?
    @ObservationIgnored private var closingBatch: Int?
    @ObservationIgnored private var batches = 0
    @ObservationIgnored private var lastOpened: (opener: UUID, tab: UUID)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var keyObserver: NSObjectProtocol?
    @ObservationIgnored private var closeObserver: NSObjectProtocol?
    /// Set when the window closes. Its state can outlive the window for a while, but it's never saved or offered again.
    @ObservationIgnored private(set) var isClosed = false
    /// Reopened from the last session, so it already knows its profile.
    @ObservationIgnored private(set) var restored = false
    var showProfilePicker = false
    @ObservationIgnored private var lockObserver: NSObjectProtocol?

    var current: Tab? { tabs.first { $0.id == selectedID } }
    var splitTab: Tab? { splitID.flatMap { id in tabs.first { $0.id == id } } }
    var pinnedTabs: [Tab] { tabs.filter(\.isPinned) }
    var regularTabs: [Tab] { tabs.filter { !$0.isPinned } }
    var canReopen: Bool { !closedTabs.isEmpty }

    init(isPrivate: Bool, profileID: UUID? = nil) {
        self.isPrivate = isPrivate
        // A window restored from the last session reopens in the profile it had.
        let snap = WebApp.isActive || isPrivate || profileID != nil ? nil : Session.shared.takePending()
        restored = snap != nil
        let pid = isPrivate ? nil : (profileID ?? snap?.profile)
        let profile = pid.flatMap { id in Settings.shared.profiles.first { $0.id == id } }
        self.profileID = profile?.id
        dataStore = isPrivate ? .nonPersistent() : profile.map { WKWebsiteDataStore(forIdentifier: $0.id) } ?? .default()
        if let profile, !isPrivate { ProfileProxies.prepare(profile, store: dataStore) }
        sidebarVisible = Settings.shared.sidebarVisible
        WindowRegistry.shared.add(self)
        ExtensionEvents.openedWindow(self)

        if let app = WebApp.url {
            newTab(url: app)
        } else if let snap {
            restore(snap)
        }
        if !isPrivate {
            for u in WindowRegistry.shared.takePendingURLs() { newTab(url: u) }
            // Tabs moved here from another window, which opened this one for them.
            if let move = WindowRegistry.shared.takePendingMove(profile: profileID) { adopt(move) }
        }
        if !WebApp.isActive { for u in WindowRegistry.shared.takeRouted(privately: isPrivate, profile: profileID) { newTab(url: u) } }
        if tabs.isEmpty { newTab() }

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.hibernateIdle() }
        if isPrivate {
            lockObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                if Settings.shared.lockPrivateWindows { self?.locked = true }
            }
        }
        // Settings are baked into a web view when it's made, so a change throws the spare away.
        spareObserver = NotificationCenter.default.addObserver(forName: .settingChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, self.spare != nil else { return }
            // Settings about Tacet's own window don't change how a page is made.
            if let key = note.userInfo?["key"] as? String, Self.windowOnlySettings.contains(key) { return }
            self.spare = nil
            self.prepareSpare()
        }
        prepareSpare()
    }

    /// Tabs, selection or split changed: the session is saved once things settle (`scheduleSave` waits).
    private func sessionChanged() {
        if !isPrivate { Session.shared.scheduleSave() }
    }

    deinit {
        timer?.invalidate()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
        if let spareObserver { NotificationCenter.default.removeObserver(spareObserver) }
        tabs.forEach { $0.close() }
        // Closing a window changes what the next launch restores.
        if !isPrivate { DispatchQueue.main.async { Session.shared.scheduleSave() } }
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        // The title bar holds tabs, so macOS must not drag the window from it; WindowDragArea moves it instead.
        window.isMovable = false
        window.titleVisibility = .hidden
        window.title = current?.title ?? "Tacet"
        WindowRegistry.shared.lastFocused = self
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            WindowRegistry.shared.lastFocused = self
            if let self { ExtensionEvents.focused(self) }
        }
        isFullScreen = window.styleMask.contains(.fullScreen)
        fullScreenObservers = [NSWindow.willEnterFullScreenNotification, NSWindow.didExitFullScreenNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                self?.isFullScreen = note.name == NSWindow.willEnterFullScreenNotification
            }
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.windowClosed()
        }
    }

    /// The window closed: it leaves the session and the extensions' window list, and its tabs stop.
    private func windowClosed() {
        guard !isClosed else { return }
        isClosed = true
        ExtensionEvents.closedWindow(self)
        // Its Space keeps the tabs, to open in any window later.
        if !isPrivate { saveSpace() }
        // It can be opened again from the History menu, with its tabs' histories.
        if !isPrivate, !WebApp.isActive, tabs.contains(where: { $0.url != nil }) { WindowRegistry.shared.rememberClosed(snapshot()) }
        // Its pages stop now (sound, video, timers), even if something still holds on to the window's state.
        for t in tabs { t.close() }
        closePreview()
        // The spare web view and its page process aren't needed any more.
        pendingSpare?.cancel()
        spare = nil
        if WindowRegistry.shared.lastFocused === self { WindowRegistry.shared.lastFocused = nil }
        if isPrivate, !WindowRegistry.shared.browsers.contains(where: { $0.isPrivate }) { DownloadManager.shared.forgetPrivate() }
        if !isPrivate { Session.shared.scheduleSave() }
    }

    private func restore(_ snap: WindowSnapshot) {
        if !isPrivate, let id = snap.space, Spaces.shared.space(id)?.profile == profileID { spaceID = id }
        groups = snap.groups ?? []
        tabs = snap.tabs.map { s in
            let t = Tab(browser: self, url: s.url, title: s.title, state: s.state, pinned: s.pinned)
            if s.pinned { t.pinnedHome = s.home ?? s.url }
            t.groupID = s.group.flatMap { g in groups.contains { $0.id == g } ? g : nil }
            if let d = s.lastActive { t.lastActive = d }
            return t
        }
        normalizeOrder()
        if !tabs.isEmpty { select(tabs[max(0, min(snap.selected, tabs.count - 1))]) }
        if let i = snap.split, tabs.indices.contains(i), tabs[i].id != selectedID {
            tabs[i].ensureWebView()
            splitID = tabs[i].id
        }
    }

    func snapshot() -> WindowSnapshot {
        WindowSnapshot(tabs: tabs.map { $0.snapshot() }, selected: tabs.firstIndex { $0.id == selectedID } ?? 0, groups: groups, profile: profileID,
                       split: splitID.flatMap { id in tabs.firstIndex { $0.id == id } }, space: spaceID)
    }

    // MARK: Link preview

    /// Opens a link over the page without leaving it (⌥-click, or right-click › Open Link in Preview). It's a whole
    /// tab, kept aside: Esc closes it, or it becomes a tab of its own or the other half of a split view.
    func openPreview(_ url: URL) {
        closePreview()
        let t = Tab(browser: self, url: url)
        t.ensureWebView()
        preview = t
    }

    func closePreview() {
        preview?.close()
        preview = nil
    }

    func keepPreview() {
        guard let t = preview else { return }
        preview = nil
        insert(t, after: current)
        select(t)
    }

    func splitPreview() {
        guard let t = preview else { return }
        preview = nil
        insert(t, after: current)
        openSplit(t)
    }

    // MARK: Spaces

    /// Keeps how this window's Space is now, so it comes back like this.
    func saveSpace() {
        guard !isPrivate, let spaceID, !tabs.isEmpty else { return }
        let snap = snapshot()
        Spaces.shared.update(spaceID) { $0.saved = snap }
    }

    /// Leaves this window's Space as it is and shows another one in its place. A Space open in another window is
    /// brought forward instead of being opened twice.
    func switchSpace(to id: UUID) {
        guard !isPrivate, id != spaceID, let target = Spaces.shared.space(id), target.profile == profileID else { return }
        if let other = WindowRegistry.shared.browsers.first(where: { $0 !== self && !$0.isClosed && $0.spaceID == id }) {
            other.window?.makeKeyAndOrderFront(nil)
            return
        }
        // Tabs open before Spaces were used aren't lost: they become a Space of their own.
        if spaceID == nil, tabs.contains(where: { $0.url != nil }) {
            spaceID = Spaces.shared.add(L("Main"), profile: profileID).id
        }
        saveSpace()
        let old = tabs
        marked = []
        splitID = nil
        selectedID = nil
        groups = []
        tabs = []
        old.forEach { $0.close() }
        spaceID = id
        if let snap = target.saved { restore(snap) }
        if tabs.isEmpty { newTab() }
    }

    /// Makes a Space and switches to it, empty.
    func newSpace(named name: String) {
        guard !isPrivate else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let space = Spaces.shared.add(trimmed.isEmpty ? String(format: L("Space %d"), Spaces.shared.items(for: profileID).count + 1) : trimmed,
                                      profile: profileID)
        switchSpace(to: space.id)
    }

    /// Deletes a Space. One open in this window is left first, for another Space or, if it was the last, for no
    /// Spaces at all; a window elsewhere showing it simply keeps its tabs outside Spaces.
    func deleteSpace(_ id: UUID) {
        guard !isPrivate, let space = Spaces.shared.space(id) else { return }
        for w in WindowRegistry.shared.browsers where w !== self && w.spaceID == id { w.spaceID = nil }
        if spaceID == id {
            if let other = Spaces.shared.items(for: profileID).first(where: { $0.id != id }) {
                switchSpace(to: other.id)
            } else {
                spaceID = nil
            }
        }
        Spaces.shared.remove(space.id)
    }

    /// Ends Spaces for this profile. Nothing is lost: the tabs of each other Space come into this window as a tab
    /// group named after it, and the Space buttons go away.
    func turnOffSpaces() {
        guard !isPrivate else { return }
        for space in Spaces.shared.items(for: profileID) where space.id != spaceID {
            if let w = WindowRegistry.shared.browsers.first(where: { $0 !== self && $0.spaceID == space.id }) {
                w.spaceID = nil
                continue
            }
            let snaps = (space.saved?.tabs ?? []).filter { $0.url != nil }
            guard !snaps.isEmpty else { continue }
            let brought = snaps.map { s in Tab(browser: self, url: s.url, title: s.title, state: s.state, pinned: false) }
            tabs += brought
            _ = group(brought, named: space.name)
        }
        spaceID = nil
        Spaces.shared.removeAll(for: profileID)
    }

    /// The next or previous Space, in the order they're listed.
    func switchSpace(by offset: Int) {
        let all = Spaces.shared.items(for: profileID)
        guard !all.isEmpty else { return }
        let i = all.firstIndex { $0.id == spaceID } ?? (offset > 0 ? -1 : 0)
        switchSpace(to: all[(i + offset + all.count) % all.count].id)
    }

    // MARK: Opening and selecting

    @discardableResult
    func newTab(url: URL? = nil, select: Bool = true, after anchor: Tab? = nil) -> Tab {
        let tab = Tab(browser: self, url: url)
        insert(tab, after: anchor ?? (Settings.shared.newTabPosition == .afterCurrent ? current : nil))
        if select { self.select(tab) }
        return tab
    }

    /// ⌘T: a fresh tab, with the command bar open unless the user turned that off.
    func newTabWithPalette() {
        newTab()
        if Settings.shared.paletteOnNewTab { showPalette("") }
    }

    private func insert(_ tab: Tab, after anchor: Tab?) {
        if let anchor, !anchor.isPinned, let i = tabs.firstIndex(where: { $0.id == anchor.id }) {
            tabs.insert(tab, at: i + 1)
        } else {
            tabs.append(tab)
        }
    }

    func select(_ tab: Tab) {
        if let g = tab.groupID, let i = groups.firstIndex(where: { $0.id == g }), groups[i].collapsed { groups[i].collapsed = false }
        if splitID == tab.id { splitID = selectedID }
        current?.lastActive = Date()
        if let old = current, old !== tab { old.rememberLook() }
        tab.ensureWebView()
        tab.lastActive = Date()
        selectedID = tab.id
        findVisible = false
        window?.title = tab.title
    }

    func select(index: Int) {
        guard !tabs.isEmpty else { return }
        select(index >= 9 ? tabs[tabs.count - 1] : tabs[min(index - 1, tabs.count - 1)])
    }

    func selectNext(_ step: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == selectedID }), tabs.count > 1 else { return }
        select(tabs[(i + step + tabs.count) % tabs.count])
    }

    func openPopup(configuration: WKWebViewConfiguration, from opener: Tab, features: WKWindowFeatures) -> WKWebView? {
        let sized = features.width != nil || features.height != nil || WebApp.isActive
        switch WebApp.isActive ? .automatic : Settings.shared.popupMode {
        case .never, .automatic:
            guard Settings.shared.popupMode == .never || sized || WebApp.isActive else { break }
            let popup = PopupWindow(configuration: configuration, features: features, opener: self) { [weak self] p in
                self?.popups.removeAll { $0 === p }
            }
            popups.append(popup)
            return popup.webView
        default:
            break
        }
        let tab = Tab(browser: self, configuration: configuration)
        tab.groupID = opener.groupID
        insert(tab, after: opener)
        select(tab)
        return tab.webView
    }

    /// ⌘-click: opens next to the opener, keeping successive links in order.
    func openInBackground(_ url: URL, from opener: Tab?, select: Bool = false) {
        if WebApp.isActive { WebApp.openInBrowser(url); return }
        if OpeningRules.route(url, from: self) { return }
        var anchor = opener
        if let opener, let last = lastOpened, last.opener == opener.id,
           let t = tabs.first(where: { $0.id == last.tab }) { anchor = t }
        let tab = newTab(url: url, select: select, after: anchor)
        tab.ensureWebView()
        if let opener { lastOpened = (opener.id, tab.id) }
    }

    func tabDidNavigate(_ tab: Tab) {
        if tab.id == selectedID { window?.title = tab.title }
        if Settings.shared.organizeTabs { autoOrganize() }
        if !isPrivate { Session.shared.scheduleSave() }
    }

    // MARK: Closing

    func close(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tab.url != nil {
            if closingBatch == nil { batches += 1 }
            closedTabs.append((tab.snapshot(), i, closingBatch ?? batches))
            if closedTabs.count > 60 { closedTabs.removeFirst() }
        }
        let wasSelected = tab.id == selectedID
        tabs.remove(at: i)
        tab.close()
        if tab.groupID != nil { cleanupGroups() }
        if splitID == tab.id { splitID = nil }
        if tabs.isEmpty {
            newTab()
        } else if wasSelected {
            select(tabs[min(i, tabs.count - 1)])
        }
    }

    /// ⌘W closes the tab; on a lone empty tab it closes the window.
    func closeCurrent() {
        guard let t = current else { return }
        if tabs.count == 1 && t.isStartPage {
            window?.performClose(nil)
        } else {
            close(t)
        }
    }

    /// Closes several tabs as one batch, which ⇧⌘T brings back whole.
    func closingTogether(_ body: () -> Void) {
        batches += 1
        let batch = batches
        closingBatch = batch
        body()
        closingBatch = nil
        let count = closedTabs.filter { $0.batch == batch }.count
        if count >= 2 { showClosedToast(count: count, batch: batch) }
    }

    /// "4 tabs closed · Undo", for a few seconds.
    private func showClosedToast(count: Int, batch: Int) {
        closedToast = (count, batch)
        toastTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.closedToast?.batch == batch else { return }
            self.closedToast = nil
        }
        toastTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timer)
    }

    func dismissClosedToast() {
        toastTimer?.cancel()
        closedToast = nil
    }

    /// The toast's Undo: the tabs it was about come back in their places, if they're still the last closed.
    func undoClosedTabs() {
        guard let batch = closedToast?.batch else { return }
        dismissClosedToast()
        if closedTabs.last?.batch == batch { reopenLastClosed() }
    }

    func closeOthers(_ keep: Tab) {
        closingTogether { for t in tabs where t.id != keep.id && !t.isPinned { close(t) } }
    }

    /// Closes tabs showing the same address as an earlier tab, keeping the selected and pinned ones.
    func closeDuplicates() {
        var seen = Set<String>()
        closingTogether {
            for t in tabs.sorted(by: { ($0.isPinned || $0.id == selectedID ? 0 : 1) < ($1.isPinned || $1.id == selectedID ? 0 : 1) }) {
                guard let key = t.url?.absoluteString else { continue }
                if seen.contains(key), !t.isPinned, t.id != selectedID { close(t) } else { seen.insert(key) }
            }
        }
    }

    func closeBelow(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        closingTogether { for t in tabs[(i + 1)...] where !t.isPinned { close(t) } }
    }

    /// ⇧⌘T: the last tab closed, or every tab closed with it, in their places.
    func reopenLastClosed() {
        guard let batch = closedTabs.last?.batch else { return }
        // Newest first, undoing the closes in reverse, so every tab lands back in its own place.
        while closedTabs.last?.batch == batch { reopenClosed() }
    }

    func reopenClosed(at position: Int? = nil) {
        guard !closedTabs.isEmpty else { return }
        let (snap, index, _) = closedTabs.remove(at: position ?? closedTabs.count - 1)
        let tab = Tab(browser: self, url: snap.url, title: snap.title, state: snap.state, pinned: snap.pinned)
        if snap.pinned { tab.pinnedHome = snap.home ?? snap.url }
        // Back into its group, if the group is still there.
        if !snap.pinned, let g = snap.group, groups.contains(where: { $0.id == g }) { tab.groupID = g }
        tabs.insert(tab, at: min(index, tabs.count))
        normalizeOrder()
        select(tab)
    }

    // MARK: Arranging

    func togglePin(_ tab: Tab) {
        tab.isPinned.toggle()
        normalizeOrder()
    }

    func duplicate(_ tab: Tab) {
        let copy = Tab(browser: self, url: tab.url, title: tab.title, state: tab.snapshot().state)
        insert(copy, after: tab)
        select(copy)
    }

    /// Handles tab IDs or URLs dropped onto a tab row or section.
    enum DropPlacement { case before, after, group }

    func handleDrop(_ items: [String], before target: Tab?, pinned: Bool) -> Bool {
        handleDrop(items, on: target, placement: .before, pinned: pinned)
    }

    /// Moves or opens dropped tabs. Dropping onto the middle of a tab groups the two.
    func handleDrop(_ items: [String], on target: Tab?, placement: DropPlacement, pinned: Bool) -> Bool {
        // Several picked tabs are dragged as one line per tab.
        let items = items.flatMap { $0.split(separator: "\n").map(String.init) }
        marked = []
        if placement == .group, let target, !target.isPinned {
            var handled = false
            for item in items {
                if let id = UUID(uuidString: item), let dragged = tabs.first(where: { $0.id == id }), dragged.id != target.id {
                    group(dragged, with: target)
                    handled = true
                } else if let url = URL(string: item), ["http", "https"].contains(url.scheme ?? "") {
                    let t = Tab(browser: self, url: url)
                    tabs.append(t)
                    group(t, with: target)
                    select(t)
                    handled = true
                }
            }
            return handled
        }
        let anchor: Tab?
        if placement == .after, let target, let i = tabs.firstIndex(where: { $0.id == target.id }) {
            anchor = tabs.indices.contains(i + 1) ? tabs[i + 1] : nil
        } else {
            anchor = target
        }
        let joinGroup = target?.groupID
        let ok = handleDropBefore(items, before: anchor, pinned: pinned, group: pinned ? nil : joinGroup)
        cleanupGroups()
        return ok
    }

    private func handleDropBefore(_ items: [String], before target: Tab?, pinned: Bool, group: UUID?) -> Bool {
        var handled = false
        var opened: Tab?
        for item in items {
            let tab: Tab
            if let id = UUID(uuidString: item), let existing = tabs.first(where: { $0.id == id }) {
                guard existing.id != target?.id else { continue }
                tabs.removeAll { $0.id == id }
                tab = existing
            } else if let url = URL(string: item), ["http", "https"].contains(url.scheme ?? "") {
                tab = Tab(browser: self, url: url)
                opened = tab
            } else {
                continue
            }
            tab.isPinned = pinned
            tab.groupID = group
            if let target, let i = tabs.firstIndex(where: { $0.id == target.id }) {
                tabs.insert(tab, at: i)
            } else if pinned, let i = tabs.lastIndex(where: \.isPinned) {
                tabs.insert(tab, at: i + 1)
            } else {
                tabs.append(tab)
            }
            handled = true
        }
        normalizeOrder()
        if let opened { select(opened) }
        return handled
    }

    /// Pinned tabs first, and the tabs of each group kept together where the group first appears.
    func normalizeOrder() {
        var regular: [Tab] = []
        var placed = Set<UUID>()
        let unpinned = tabs.filter { !$0.isPinned }
        // Each group's tabs, gathered once, so many groups don't mean scanning every tab for each.
        let members = Dictionary(grouping: unpinned.filter { $0.groupID != nil }, by: { $0.groupID! })
        for t in unpinned {
            guard let g = t.groupID else { regular.append(t); continue }
            if placed.contains(g) { continue }
            placed.insert(g)
            regular += members[g] ?? []
        }
        tabs = tabs.filter(\.isPinned) + regular
    }

    // MARK: Groups

    func group(_ dragged: Tab, with target: Tab) {
        dragged.isPinned = false
        if let g = target.groupID {
            dragged.groupID = g
        } else {
            let sameSite = dragged.host.map(PasswordStore.site) == target.host.map(PasswordStore.site) ? target.host.map(PasswordStore.site) : nil
            let new = TabGroup(name: sameSite.map(Self.siteName) ?? L("New Group"), color: groups.count)
            groups.append(new)
            target.groupID = new.id
            dragged.groupID = new.id
        }
        tabs.removeAll { $0.id == dragged.id }
        if let i = tabs.lastIndex(where: { $0.groupID == dragged.groupID }) { tabs.insert(dragged, at: i + 1) } else { tabs.append(dragged) }
        cleanupGroups()
    }

    func tabs(in group: TabGroup) -> [Tab] { tabs.filter { $0.groupID == group.id } }

    func newGroup(with tab: Tab) {
        let g = TabGroup(name: tab.host.map { Self.siteName(PasswordStore.site($0)) } ?? L("New Group"), color: groups.count)
        groups.append(g)
        tab.groupID = g.id
        cleanupGroups()
    }

    func renameGroup(_ id: UUID, _ name: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        groups[i].name = trimmed.isEmpty ? groups[i].name : trimmed
        groups[i].site = nil // a renamed group is yours now
    }

    func toggleCollapsed(_ id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].collapsed.toggle()
        if groups[i].collapsed, let current, current.groupID == id,
           let next = tabs.first(where: { $0.groupID != id && !$0.isPinned }) ?? tabs.first(where: { $0.groupID != id }) {
            select(next)
        }
    }

    func setColor(_ id: UUID, _ color: Int) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].color = color
    }

    func ungroup(_ id: UUID) {
        for t in tabs where t.groupID == id { t.groupID = nil }
        groups.removeAll { $0.id == id }
        normalizeOrder()
    }

    func removeFromGroup(_ tab: Tab) {
        tab.groupID = nil
        cleanupGroups()
    }

    func closeGroup(_ id: UUID) {
        closingTogether { for t in tabs where t.groupID == id { close(t) } }
        groups.removeAll { $0.id == id }
    }

    /// Drops empty groups (and site groups down to one tab) and keeps members together.
    func cleanupGroups() {
        for g in groups {
            let count = tabs.filter { $0.groupID == g.id }.count
            if count == 0 || (g.site != nil && count < 2) {
                for t in tabs where t.groupID == g.id { t.groupID = nil }
                groups.removeAll { $0.id == g.id }
            }
        }
        normalizeOrder()
    }

    /// Groups ungrouped tabs from the same site under the site's name, once there are as many as the user chose
    /// (three unless they changed it). Sites the user excluded are never grouped.
    func autoOrganize() {
        let threshold = max(2, Settings.shared.groupThreshold)
        var changed = dropExceptedGroups()
        // A tab that left its site group's site, or was opened from it on another site, leaves the group.
        for t in tabs {
            guard let g = t.groupID, let site = groups.first(where: { $0.id == g })?.site,
                  let host = t.host, ["http", "https"].contains(t.url?.scheme ?? ""),
                  PasswordStore.site(host) != site else { continue }
            t.groupID = nil
            changed = true
        }
        var bySite: [String: [Tab]] = [:]
        for t in tabs where !t.isPinned {
            guard let host = t.host, ["http", "https"].contains(t.url?.scheme ?? "") else { continue }
            let auto = t.groupID.flatMap { g in groups.first { $0.id == g } }?.site
            if t.groupID != nil && auto == nil { continue } // grouped by you: leave it alone
            let site = PasswordStore.site(host)
            if Settings.shared.groupExceptions.contains(site) { continue }
            bySite[site, default: []].append(t)
        }
        // Sorted, so groups are made in the same order every time.
        for (site, members) in bySite.sorted(by: { $0.key < $1.key }) where members.count >= threshold {
            let group: TabGroup
            if let existing = groups.first(where: { $0.site == site }) {
                group = existing
            } else {
                group = TabGroup(name: Self.siteName(site), color: groups.count, site: site)
                groups.append(group)
            }
            for t in members where t.groupID != group.id { t.groupID = group.id; changed = true }
        }
        if changed { cleanupGroups() }
    }

    static func siteName(_ site: String) -> String {
        let brands = ["github": "GitHub", "youtube": "YouTube", "stackoverflow": "Stack Overflow", "linkedin": "LinkedIn",
                      "gitlab": "GitLab", "icloud": "iCloud", "chatgpt": "ChatGPT", "openai": "OpenAI", "x": "X",
                      "duckduckgo": "DuckDuckGo", "wikipedia": "Wikipedia", "tiktok": "TikTok", "paypal": "PayPal",
                      "ebay": "eBay", "whatsapp": "WhatsApp", "soundcloud": "SoundCloud", "deviantart": "DeviantArt"]
        let name = String(site.split(separator: ".").first ?? Substring(site))
        return brands[name.lowercased()] ?? name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: Split view

    func openSplit(_ tab: Tab) {
        guard tab.id != selectedID else { return }
        tab.ensureWebView()
        splitID = tab.id
    }

    func splitWithNewTab() {
        let t = newTab(select: false)
        t.ensureWebView()
        splitID = t.id
    }

    func swapSplit() {
        guard let s = splitID, let c = selectedID else { return }
        selectedID = s
        splitID = c
    }

    /// Ends split view. A new tab opened for it and never used closes with it.
    func closeSplit() {
        let side = splitTab
        splitID = nil
        if let side, side.isStartPage, !side.isPinned, side.id != selectedID, tabs.count > 1 { close(side) }
    }

    // MARK: Memory

    func hibernateIdle() {
        let days = Settings.shared.autoCloseDays
        if days > 0 {
            let old = Date().addingTimeInterval(-Double(days) * 86_400)
            for t in tabs where !t.isPinned && !t.isSelected && !t.isPlayingAudio && !t.isCapturing && t.lastActive < old { close(t) }
        }
        var minutes = Double(Settings.shared.hibernateMinutes)
        guard minutes > 0 else { return }
        // In Low Power Mode background tabs go to sleep three times sooner.
        if Power.shared.lowPower { minutes = max(2, minutes / 3) }
        hibernate(idleFor: minutes * 60)
    }

    /// Hibernates background tabs unused for `seconds`, except ones playing sound or using the camera or microphone.
    func hibernate(idleFor seconds: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-seconds)
        for t in tabs where !t.isSelected && !t.isHibernated && !t.isPlayingAudio && !t.isCapturing && t.lastActive <= cutoff {
            t.hibernate()
        }
    }

    func hibernateOthers() { hibernate(idleFor: 0) }

    // MARK: Window lock

    /// True when the user locked the window from the File menu, so the lock waits for them instead of asking right away.
    private(set) var lockedByUser = false

    /// Covers the window until Touch ID or the Mac password unlocks it.
    func lock() {
        guard !locked else { return }
        paletteVisible = false
        findVisible = false
        lockedByUser = true
        locked = true
        // Keys typed while locked must not reach the page underneath.
        window?.makeFirstResponder(nil)
    }

    @ObservationIgnored private var unlocking = false

    func unlock() {
        guard locked, !unlocking else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { finishUnlock(); return }
        unlocking = true
        let reason = L(isPrivate ? "unlock your private window" : "unlock this window")
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async {
                self.unlocking = false
                if ok { self.finishUnlock() }
            }
        }
    }

    private func finishUnlock() {
        locked = false
        lockedByUser = false
    }

    // MARK: Spare web view

    /// Settings that only change Tacet's own window, often while you use it (⌘S, zoom, dragging a panel's edge).
    private static let windowOnlySettings: Set<String> = [
        "sidebarVisible", "sidebarWidth", "assistantWidth", "siteZoom", "theme", "accent", "tabLayout", "sidebarSide",
        "chromeStyle", "compactTabs", "aiModels", "aiProvider", "aiWeb", "aiControl", "welcomedVersion", "aiIntroduced",
        "mediaPermissions", "neverSave", "automations", "openingRules", "groupExceptions",
    ]

    /// A web view built ahead of time, so the next new tab doesn't wait while one is made and its scripts are set up.
    @ObservationIgnored private var spare: LumenWebView?
    @ObservationIgnored private var spareObserver: NSObjectProtocol?

    /// Lets the spare web view go when memory is short; the next new tab makes its own.
    func releaseSpare() {
        pendingSpare?.cancel()
        spare = nil
    }

    func takeSpareWebView() -> LumenWebView? {
        let wv = spare
        spare = nil
        prepareSpare()
        return wv
    }

    @ObservationIgnored private var pendingSpare: DispatchWorkItem?

    /// Builds the spare a moment from now. Settings changing in a burst (dragging a panel's edge, say) build it once.
    private func prepareSpare() {
        // Low Power Mode skips it: the next tab builds its own when it's needed.
        guard !Power.shared.lowPower, !WebApp.isActive else { return }
        pendingSpare?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.spare == nil, !self.isClosed, !Power.shared.lowPower else { return }
            self.spare = LumenWebView(frame: .zero, configuration: Tab.configuration(store: self.dataStore))
        }
        pendingSpare = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: Overlays

    func showPalette(_ prefill: String? = nil) {
        guard !locked else { return }
        palettePrefill = prefill ?? current?.url?.absoluteString ?? ""
        findVisible = false
        paletteVisible = true
    }

    /// ⌘L and ⌘K: the same shortcut that opens the command bar closes it.
    func togglePalette(_ prefill: String? = nil) {
        if paletteVisible { paletteVisible = false } else { showPalette(prefill) }
    }

    func showFind() {
        paletteVisible = false
        findVisible = true
    }
}
