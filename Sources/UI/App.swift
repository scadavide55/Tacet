import SwiftUI
import WebKit

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // A restored backup's files go in before anything reads them.
        Backup.applyPendingRestore()
    }

    var body: some Scene {
        WindowGroup("Tacet", id: "main") {
            ContentView(isPrivate: false)
        }
        // Links opened from other apps go to the app delegate, which puts them in tabs; without this
        // SwiftUI would also open an empty window for each one.
        .handlesExternalEvents(matching: [])
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { LumenCommands() }

        WindowGroup("Tacet", id: "profile", for: UUID.self) { $profile in
            ContentView(isPrivate: false, profileID: profile)
        }
        .handlesExternalEvents(matching: [])
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)

        WindowGroup("Private Window", id: "private") {
            ContentView(isPrivate: true)
        }
        .handlesExternalEvents(matching: [])
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)

        Window("Library", id: "library") {
            LibraryView()
        }
        // Opened from their own menu items, so the Window menu doesn't list them a second time.
        .commandsRemoved()
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 820, height: 560)

        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutList().padding(24).frame(width: 760)
        }
        // Opened from their own menu items, so the Window menu doesn't list them a second time.
        .commandsRemoved()
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)

        Window("About Tacet", id: "about") {
            AboutView()
        }
        // Opened from their own menu items, so the Window menu doesn't list them a second time.
        .commandsRemoved()
        .handlesExternalEvents(matching: [])
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("Software Update", id: "update") {
            UpdateView()
        }
        // Opened from their own menu items, so the Window menu doesn't list them a second time.
        .commandsRemoved()
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)

        Window("Tacet Plugins", id: "plugins") {
            PluginsView()
        }
        // Opened from their own menu items, so the Window menu doesn't list them a second time.
        .commandsRemoved()
        .handlesExternalEvents(matching: [])

        Window("Import", id: "import") {
            ImportView()
        }
        // Opened from their own menu items, so the Window menu doesn't list them a second time.
        .commandsRemoved()
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)

        SwiftUI.Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tacet restores its own session, so macOS shouldn't reopen windows on top of it.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        Settings.shared.applyTheme()
        ContentBlocker.shared.start()
        Power.shared.start()
        // Reading the Public Suffix List takes a moment; it's done in the background before tabs and groups need it.
        DispatchQueue.global(qos: .userInitiated).async { _ = PublicSuffix.registrable("www.example.com") }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        UpdateChecker.shared.check()
        PendingImport.retry()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Self.handleExtraShortcut(event) { return nil }
            // Keyboard shortcuts that extensions define.
            if #available(macOS 15.4, *), event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                for (_, context) in Extensions.shared.loaded where context.performCommand(for: event) { return nil }
            }
            return event
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            ProfileCleanup.finishPending()
            Favicons.shared.prune()
            if !WebApp.isActive {
                PublicSuffix.refreshIfStale()
                WebApp.refreshInstalled()
                // Installed plugins update themselves at launch, verified as always.
                if !PluginStore.shared.installed.isEmpty { Task { await PluginStore.shared.refresh() } }
            }
        }
        if #available(macOS 15.4, *) { Extensions.shared.start() }
        AppIcon.applyChosen()
        PageText.shared.prune(keepingDays: Settings.shared.pageTextDays)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        if WebApp.isActive { urls.forEach(WebApp.openInBrowser); return }
        if !WindowRegistry.shared.open(urls) { Self.openWindowWhenReady() }
    }

    /// Opening Tacet from a link can leave it without a window, since no window claims the link at launch.
    /// The new window picks up the link (and the saved session) once the menus exist.
    private static func openWindowWhenReady(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard !WindowRegistry.shared.browsers.contains(where: { !$0.isPrivate }) else {
                // A window opened meanwhile: it takes the links waiting for it.
                if !WindowRegistry.shared.pendingURLs.isEmpty { WindowRegistry.shared.open(WindowRegistry.shared.takePendingURLs()) }
                return
            }
            if NSApp.mainMenu?.items.isEmpty == false {
                openNewWindow()
            } else if attempt < 25 {
                openWindowWhenReady(attempt: attempt + 1)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let downloads = DownloadManager.shared.active.count
        guard downloads > 0 else { return saveForQuit(sender) }
        // Installing an update quits by itself; otherwise you decide.
        if !AppRename.skip {
            let alert = NSAlert()
            alert.messageText = downloads == 1 ? L("A download is still in progress") : String(format: L("%d downloads are still in progress"), downloads)
            alert.informativeText = L("If you quit now, Tacet pauses what's downloading, so you can resume it when you open Tacet again.")
            alert.addButton(withTitle: L("Quit"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        DownloadManager.shared.pauseForQuit {
            if self.saveForQuit(sender) == .terminateNow { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    /// Writes everything still waiting, then clears browsing data if the user asked for that on quit.
    private func saveForQuit(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Session.shared.saveNow()
        for b in WindowRegistry.shared.browsers { b.saveSpace() }
        Spaces.shared.saveNow()
        AppRename.afterQuit()
        History.shared.flush()
        PageText.shared.flush()
        AssistantHistory.shared.flush()
        StoredFiles.flushAll()
        guard Settings.shared.clearOnQuit else { return .terminateNow }
        DataCleaner.clear(range: .all, history: true, cookies: true, cache: true) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Opens a browser window from AppKit code, through the File menu's New Window item.
    /// Found by its ⌘N shortcut, since the title changes with the language.
    static func openNewWindow() {
        let isNewWindow: (NSMenuItem) -> Bool = {
            $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
        }
        guard let file = NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains(where: isNewWindow) == true })?.submenu,
              let index = file.items.firstIndex(where: isNewWindow) else { return }
        file.performActionForItem(at: index)
    }

    /// Shortcuts that menus can't express: ⌘= next to ⌘+, ⇧⌘] / ⇧⌘[ and ⌥⌘→ / ⌥⌘← to switch tabs.
    private static func handleExtraShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        // Esc closes a link preview, wherever the keyboard is; ⌘↩ keeps it as a tab.
        if let b = WindowRegistry.shared.lastFocused, b.preview != nil, b.window?.isKeyWindow == true {
            if flags.isEmpty, event.keyCode == 53 { b.closePreview(); return true }
            if flags == [.command], event.keyCode == 36 { b.keepPreview(); return true }
        }
        guard flags.contains(.command), let b = WindowRegistry.shared.lastFocused, b.window?.isKeyWindow == true else { return false }
        // ⌃⌥⌘1 to ⌃⌥⌘9 run the automation with that shortcut.
        if flags == [.control, .option, .command], let n = Int(event.charactersIgnoringModifiers ?? ""),
           let a = Settings.shared.automations.first(where: { $0.shortcut == n }) {
            Task { @MainActor in await AutomationRunner.run(a, in: b) }
            return true
        }
        switch (flags, event.keyCode) {
        case ([.command], 24) where event.charactersIgnoringModifiers == "=":
            b.current?.zoom(1)
        case ([.command, .shift], 30), ([.command, .option], 124):
            b.selectNext(1)
        case ([.command, .shift], 33), ([.command, .option], 123):
            b.selectNext(-1)
        default:
            return false
        }
        return true
    }
}

// MARK: - Menus

struct LumenCommands: Commands {
    @FocusedValue(\.browser) private var b
    @Environment(\.openWindow) private var openWindow
    @Bindable private var s = Settings.shared
    private var bookmarks = Bookmarks.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                if let b { b.newTabWithPalette() } else { openWindow(id: "main") }
            }
            .keyboardShortcut("t")
            Button("New Window") { openWindow(id: "main") }.keyboardShortcut("n")
            Button("New Private Window") { openWindow(id: "private") }.keyboardShortcut("n", modifiers: [.command, .shift])
            if !s.profiles.isEmpty {
                Menu("New Window in Profile") {
                    ForEach(s.profiles) { p in Button(p.name) { openWindow(id: "profile", value: p.id) } }
                }
            }
            Divider()
            Button("Open Location…") { b?.togglePalette() }.keyboardShortcut("l").disabled(b == nil)
            // With no closed tab to bring back here, ⇧⌘T brings back the last closed window, as in Safari.
            Button("Reopen Closed Tab") {
                if let b, b.canReopen { b.reopenLastClosed() } else { reopenClosedWindow() }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Close Tab") {
                if let b { b.closeCurrent() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Import from Another Browser…") { openWindow(id: "import") }
            Button("Print…") { b?.current?.printPage() }.keyboardShortcut("p").disabled(b == nil)
            Button("Install Site as App…") { b?.showInstallApp = true }.disabled(b?.current?.url == nil || WebApp.isActive)
            Button("Export as PDF…") { b?.current?.exportPDF() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(b == nil)
            Button("Take Screenshot of Page") { b?.current?.screenshot() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(b == nil)
            Divider()
            Button("Lock Window with Touch ID") { b?.lock() }.keyboardShortcut("l", modifiers: [.command, .control]).disabled(b == nil || b?.locked == true)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Link") {
                guard let url = b?.current?.url else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(b == nil)
            Divider()
            Button("Find…") { b?.showFind() }.keyboardShortcut("f").disabled(b == nil)
            Button("Find Next") { findAgain(backwards: false) }.keyboardShortcut("g").disabled(b == nil)
            Button("Find Previous") { findAgain(backwards: true) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(b == nil)
        }

        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") { b?.sidebarVisible.toggle() }.keyboardShortcut("s").disabled(b == nil)
            Button("Command Bar") { b?.togglePalette("") }.keyboardShortcut("k").disabled(b == nil)
            if s.aiEnabled {
                Button("Tacet Assistant") { b?.assistantVisible.toggle() }.keyboardShortcut("a", modifiers: [.command, .shift]).disabled(b == nil)
            }
            Divider()
            Button("Reader") { b?.current?.toggleReader() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(b == nil)
            if b?.current?.translatedFrom != nil {
                Button("Show Original") { b?.current?.showOriginal() }.keyboardShortcut("t", modifiers: [.command, .option])
            } else {
                Button("Translate Page") { b?.current?.translatePage() }
                    .keyboardShortcut("t", modifiers: [.command, .option]).disabled(b?.current?.url == nil)
            }
            Button(b?.current?.readingAloud == true ? "Stop Reading Aloud" : "Read Aloud") {
                if let t = b?.current { ReadAloud.shared.toggle(t) }
            }
            .keyboardShortcut("a", modifiers: [.command, .option]).disabled(b?.current?.url == nil)
            Button(b?.focusMode == true ? "Exit Focus Mode" : "Focus Mode") { b?.focusMode.toggle() }
                .keyboardShortcut("j", modifiers: [.command, .shift]).disabled(b == nil)
            Button("Split View") {
                guard let b else { return }
                b.splitTab == nil ? b.splitWithNewTab() : b.closeSplit()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(b == nil)
            Divider()
            Button("Zoom In") { b?.current?.zoom(1) }.keyboardShortcut("+").disabled(b == nil)
            Button("Zoom Out") { b?.current?.zoom(-1) }.keyboardShortcut("-").disabled(b == nil)
            Button("Actual Size") { b?.current?.zoom(0) }.keyboardShortcut("0").disabled(b == nil)
            Divider()
            Button("Reload Page") { b?.current?.reload() }.keyboardShortcut("r").disabled(b == nil)
            Button("Reload Ignoring Cache") { b?.current?.hardReload() }.keyboardShortcut("r", modifiers: [.command, .option]).disabled(b == nil)
            Button("Stop Loading") { b?.current?.stop() }.keyboardShortcut(".").disabled(b == nil)
            Divider()
        }

        CommandMenu("History") {
            Button("Back") { b?.current?.goBack() }.keyboardShortcut("[").disabled(b == nil)
            Button("Forward") { b?.current?.goForward() }.keyboardShortcut("]").disabled(b == nil)
            Divider()
            Button("Show All History") { library(.history) }.keyboardShortcut("y")
            Button("Reopen Closed Window") { reopenClosedWindow() }.disabled(WindowRegistry.shared.closedWindows.isEmpty)
            if let b, !b.closedTabs.isEmpty {
                Divider()
                Text("Recently Closed")
                ForEach(Array(b.closedTabs.enumerated().reversed().prefix(10)), id: \.offset) { i, item in
                    Button(item.snapshot.title) { b.reopenClosed(at: i) }
                }
            }
            Menu("Clear History") {
                Button("Last Hour") { History.shared.clear(since: Date().addingTimeInterval(-3600)) }
                Button("Today") { History.shared.clear(since: Calendar.current.startOfDay(for: Date())) }
                Button("All History") { History.shared.clear() }
            }
        }

        CommandMenu("Bookmarks") {
            Button("Bookmark This Page") {
                guard let t = b?.current else { return }
                bookmarks.toggle(url: t.url, title: t.title)
            }
            .keyboardShortcut("d")
            .disabled(b == nil)
            Button("Show Bookmarks") { library(.bookmarks) }.keyboardShortcut("b", modifiers: [.command, .option])
            Divider()
            Button("Save for Offline") { b?.current?.saveForOffline() }.disabled(b == nil || b?.isPrivate == true || b?.current?.url == nil)
            Button("Show Reading List") { library(.readingList) }
            if !bookmarks.items.isEmpty { Divider() }
            ForEach(bookmarks.items.prefix(30)) { bm in
                Button(bm.title) {
                    if let b { b.newTab(url: bm.url) } else if !WindowRegistry.shared.open([bm.url]) { openWindow(id: "main") }
                }
            }
        }

        CommandMenu("Tab") {
            Button("Next Tab") { b?.selectNext(1) }.keyboardShortcut(.tab, modifiers: .control).disabled(b == nil)
            Button("Previous Tab") { b?.selectNext(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled(b == nil)
            Divider()
            Button("Pin or Unpin Tab") { if let b, let t = b.current { b.togglePin(t) } }.disabled(b == nil)
            Button("Duplicate Tab") { if let b, let t = b.current { b.duplicate(t) } }.disabled(b == nil)
            Button("Mute or Unmute Tab") { if let t = b?.current { t.setMuted(!t.isMuted) } }
                .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(b == nil)
            Button("Hibernate Other Tabs") { b?.hibernateOthers() }.disabled(b == nil)
            Divider()
            Button("Group Tabs by Site") { b?.groupBySiteNow() }.disabled(b == nil)
            Button("Search Tabs…") {
                // The sidebar's search when the sidebar shows; otherwise the command bar, which finds open tabs too.
                if Settings.shared.tabLayout == .vertical, b?.sidebarVisible == true { b?.tabFilterVisible = true } else { b?.showPalette("") }
            }
            .keyboardShortcut("f", modifiers: [.command, .option]).disabled(b == nil)
            Button("Close Duplicate Tabs") { b?.closeDuplicates() }.disabled(b == nil || b?.duplicateCount == 0)
            Menu("Sort Tabs") {
                ForEach(BrowserState.TabSort.allCases) { o in Button(o.label) { b?.sortTabs(by: o) } }
            }
            .disabled(b == nil)
            if let b, !b.isPrivate, !SavedGroups.shared.items.isEmpty {
                Menu("Saved Groups") {
                    ForEach(SavedGroups.shared.items) { g in Button(g.name) { b.open(g) } }
                }
            }
            Divider()
            if let b, !s.automations.isEmpty {
                Menu("Automations") {
                    ForEach(s.automations) { a in
                        Button(a.name) { Task { @MainActor in await AutomationRunner.run(a, in: b) } }
                    }
                }
                Divider()
            }
            Button("New Space…") { if let b { SpaceActions.askNew(in: b) } }.disabled(b == nil || b?.isPrivate == true)
            if let b, !b.isPrivate, !Spaces.shared.items(for: b.profileID).isEmpty {
                Button("Turn Off Spaces…") { SpaceActions.askTurnOff(in: b) }
            }
            Button("Next Space") { b?.switchSpace(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
                .disabled(b == nil || b?.isPrivate == true || Spaces.shared.items(for: b?.profileID).isEmpty)
            Button("Previous Space") { b?.switchSpace(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
                .disabled(b == nil || b?.isPrivate == true || Spaces.shared.items(for: b?.profileID).isEmpty)
            if let b, !b.isPrivate, !Spaces.shared.items(for: b.profileID).isEmpty {
                Menu("Spaces") {
                    ForEach(Spaces.shared.items(for: b.profileID)) { sp in
                        Toggle(sp.name, isOn: Binding(get: { b.spaceID == sp.id }, set: { _ in b.switchSpace(to: sp.id) }))
                    }
                }
            }
            Divider()
            ForEach(1...9, id: \.self) { i in
                Button(i == 9 ? LocalizedStringKey("Last Tab") : "Tab \(i)") { b?.select(index: i) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i))))
                    .disabled(b == nil)
            }
        }

        // Only in Developer Mode, as in Safari; the command bar and Settings › Advanced turn it on.
        if s.developer {
            CommandMenu("Develop") {
                // With the Web Inspector's own window in front, the menu still works on the window it inspects.
                DevelopMenuItems(b: b ?? WindowRegistry.shared.lastFocused, shortcuts: true)
            }
        }

        CommandMenu("Shield") {
            Toggle("Block Ads and Trackers", isOn: $s.adBlock).keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Toggle Shield for This Site") {
                guard let host = b?.current?.host else { return }
                s.setAllowlisted(host, !s.isAllowlisted(host))
            }
            .disabled(b == nil || !s.adBlock)
            Divider()
            Toggle("Hide Cookie Banners", isOn: $s.hideCookieBanners).disabled(!s.adBlock)
            Toggle("Skip YouTube Ads", isOn: $s.youtubeAds).disabled(!s.adBlock)
            Toggle("Block Third-Party Cookies", isOn: $s.blockThirdPartyCookies)
            Toggle("Remove Tracking from Links", isOn: $s.stripTracking)
        }

        // Downloads and Tacet Plugins open windows of their own, so they're in the Window menu, as in Safari.
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Downloads") { library(.downloads) }.keyboardShortcut("l", modifiers: [.command, .option])
            Button("Tacet Plugins") { openWindow(id: "plugins") }.keyboardShortcut("p", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .appInfo) {
            Button("About Tacet") { openWindow(id: "about") }
            Button("Check for Updates…") { UpdateChecker.shared.check(force: true) { openWindow(id: "update") } }
        }

        CommandGroup(replacing: .help) {
            Button("Welcome to Tacet…") {
                if let b { b.showOnboarding = true } else { openWindow(id: "main") }
            }
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
            Divider()
            Button("Tacet Website") { NSWorkspace.shared.open(URL(string: "https://scadavide55.github.io/Tacet/")!) }
            Button("Report a Bug") { NSWorkspace.shared.open(URL(string: "https://github.com/scadavide55/Tacet/issues")!) }
        }
    }

    private func reopenClosedWindow() {
        guard let snap = WindowRegistry.shared.takeClosedWindow() else { return }
        Session.shared.reopen(snap)
        openWindow(id: "main")
    }

    private func library(_ section: LibraryView.Section) {
        LibraryView.requestedSection = section
        openWindow(id: "library")
    }

    private func findAgain(backwards: Bool) {
        guard let b else { return }
        if b.findVisible {
            NotificationCenter.default.post(name: .findAgain, object: backwards)
        } else {
            b.showFind()
        }
    }
}
