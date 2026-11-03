import SwiftUI

struct Sidebar: View {
    let showsControls: Bool
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                if s.sidebarSide == .left && !b.isFullScreen { Spacer().frame(width: 70) }
                Spacer(minLength: 0)
                if showsControls {
                    SidebarToggle()
                    if let tab = b.current { NavButtons(tab: tab) }
                }
            }
            .frame(height: 28)
            .background(WindowDragArea())

            if showsControls, let tab = b.current {
                AddressPill(tab: tab)
            }
            if b.isPrivate { PrivateBadge() }
            if let p = b.profile { ProfileBadge(profile: p) }
            if let space = b.space { SpaceHeader(space: space) }
            if !b.pinnedTabs.isEmpty { PinnedGrid() }

            if b.tabFilterVisible || b.tabs.count >= 12 { TabFilterField() }

            ScrollView {
                LazyVStack(spacing: 2) {
                    NewTabRow()
                    if b.duplicateCount > 0 { DuplicatesRow(count: b.duplicateCount) }
                    ForEach(entries) { entry in
                        switch entry {
                        case .header(let g): GroupHeader(group: g)
                        case .tab(let t, let grouped):
                            TabRow(tab: t, browser: b, grouped: grouped, selected: b.selectedID == t.id,
                                   inSplit: b.splitID == t.id, groupTint: grouped ? b.groups.first { $0.id == t.groupID }?.tint : nil,
                                   compact: s.compactTabs, marked: b.marked.contains(t.id))
                                .equatable()
                        }
                    }
                    if !b.isPrivate { SavedGroupsSection() }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .dropDestination(for: String.self) { items, _ in b.handleDrop(items, before: nil, pinned: false) }

            if !b.isPrivate { SpaceBar() }
            SidebarFooter(showsDownloads: showsControls)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

struct SidebarToggle: View {
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared

    var body: some View {
        IconButton(systemName: s.sidebarSide == .left ? "sidebar.left" : "sidebar.right", help: "Toggle sidebar (⌘S)") {
            b.peekSidebar = false
            b.sidebarVisible.toggle()
        }
    }
}

struct NavButtons: View {
    var tab: Tab

    var body: some View {
        HStack(spacing: 2) {
            IconButton(systemName: "chevron.left", help: "Back (⌘[)") { tab.goBack() }.disabled(!tab.canGoBack)
            IconButton(systemName: "chevron.right", help: "Forward (⌘])") { tab.goForward() }.disabled(!tab.canGoForward)
            IconButton(systemName: tab.isLoading ? "xmark" : "arrow.clockwise", help: tab.isLoading ? "Stop" : "Reload (⌘R)") {
                tab.isLoading ? tab.stop() : tab.reload()
            }
            .disabled(tab.url == nil && tab.failedURL == nil)
        }
    }
}

struct PrivateBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eyeglasses")
            Text("Private window").font(.system(size: 11.5, weight: .medium))
            Spacer()
        }
        .foregroundStyle(.purple)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help("History, cookies and site data from this window are forgotten when you close it.")
    }
}

/// Names the profile a window uses, in its colour.
struct ProfileBadge: View {
    let profile: Profile
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.fill")
            Text(profile.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            if !compact { Spacer() }
        }
        .foregroundStyle(profile.tint)
        .padding(.horizontal, compact ? 8 : 10)
        .frame(height: compact ? 24 : 26)
        .background(profile.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help("This window uses the cookies, sign-ins and site data of this profile.")
    }
}

struct NewTabRow: View {
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 16)
            Text("New Tab").font(.system(size: 12.5))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: s.compactTabs ? 28 : 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { b.newTabWithPalette() }
        .onHover { hover = $0 }
        .help("New tab (⌘T)")
    }
}

/// A row in the sidebar's tab list: a group header or a tab.
enum SidebarEntry: Identifiable {
    case header(TabGroup)
    case tab(Tab, grouped: Bool)

    var id: String {
        switch self {
        case .header(let g): "g" + g.id.uuidString
        case .tab(let t, _): t.id.uuidString
        }
    }
}

extension Sidebar {
    var entries: [SidebarEntry] {
        var out: [SidebarEntry] = []
        var seen = Set<UUID>()
        let words = b.tabFilter.lowercased().split(separator: " ").map(String.init)
        if !words.isEmpty {
            // Searching: every matching tab, with its group's name above it, folded groups included.
            for t in b.regularTabs {
                let hay = (t.title + " " + (t.url?.absoluteString ?? "")).lowercased()
                guard words.allSatisfy(hay.contains) else { continue }
                if let gid = t.groupID, let g = b.groups.first(where: { $0.id == gid }) {
                    if seen.insert(gid).inserted { out.append(.header(g)) }
                    out.append(.tab(t, grouped: true))
                } else {
                    out.append(.tab(t, grouped: false))
                }
            }
            return out
        }
        for t in b.regularTabs {
            if let gid = t.groupID, let g = b.groups.first(where: { $0.id == gid }) {
                if !seen.contains(gid) { seen.insert(gid); out.append(.header(g)) }
                if !g.collapsed { out.append(.tab(t, grouped: true)) }
            } else {
                out.append(.tab(t, grouped: false))
            }
        }
        return out
    }
}

/// Search the open tabs by title or address; Esc clears it. Shown with ⌥⌘F, and always once there are many tabs.
struct TabFilterField: View {
    @Environment(BrowserState.self) var b
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var b = b
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(L("Search tabs"), text: $b.tabFilter)
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .focused($focused)
                .onExitCommand { b.tabFilter = ""; b.tabFilterVisible = false; focused = false }
                .onSubmit {
                    // Return opens the first match.
                    let words = b.tabFilter.lowercased().split(separator: " ").map(String.init)
                    if let t = b.regularTabs.first(where: { t in
                        let hay = (t.title + " " + (t.url?.absoluteString ?? "")).lowercased()
                        return words.allSatisfy(hay.contains)
                    }) { b.select(t) }
                    b.tabFilter = ""
                    b.tabFilterVisible = false
                }
            if !b.tabFilter.isEmpty {
                Button { b.tabFilter = "" } label: { Label("Clear", systemImage: "xmark.circle.fill").labelStyle(.iconOnly).font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        .onAppear { if b.tabFilterVisible { focused = true } }
        .onChange(of: b.tabFilterVisible) { _, visible in if visible { focused = true } }
    }
}

struct GroupHeader: View {
    let group: TabGroup
    @Environment(BrowserState.self) var b
    @State private var hover = false
    @State private var renaming = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Circle().fill(group.tint).frame(width: 8, height: 8)
            if renaming {
                TextField("Group name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { renaming = false }
            } else {
                Text(group.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("\(b.tabs(in: group).count)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(group.tint.opacity(hover ? 0.16 : 0.09)))
        .contentShape(Rectangle())
        // One gesture, read from the click itself: waiting to see whether a double-click follows would hold
        // the first click back by the double-click interval. A second click undoes the fold and renames instead.
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                withAnimation(.easeOut(duration: 0.15)) { b.toggleCollapsed(group.id) }
                startRename()
            } else {
                withAnimation(.easeOut(duration: 0.15)) { b.toggleCollapsed(group.id) }
            }
        }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Rename Group…") { startRename() }
            GroupMenu(group: group)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let last = b.tabs(in: group).last else { return false }
            return b.handleDrop(items, on: last, placement: .group, pinned: false)
        }
        .help(L("Click to collapse, double-click to rename"))
    }

    static let colorNames = [L("Blue"), L("Purple"), L("Pink"), L("Orange"), L("Green"), L("Teal"), L("Yellow"), L("Grey")]

    private func startRename() {
        name = group.name
        renaming = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        b.renameGroup(group.id, name)
        renaming = false
    }
}

/// Gets what it shows from the sidebar as plain values instead of watching the whole window,
/// so opening the command bar or switching tabs only redraws the rows that change.
struct TabRow: View, Equatable {
    var tab: Tab
    let browser: BrowserState
    var grouped = false
    let selected: Bool
    let inSplit: Bool
    let groupTint: Color?
    let compact: Bool
    var marked = false
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    private var b: BrowserState { browser }

    static func == (l: TabRow, r: TabRow) -> Bool {
        l.tab === r.tab && l.browser === r.browser && l.grouped == r.grouped && l.selected == r.selected
            && l.inSplit == r.inSplit && l.groupTint == r.groupTint && l.compact == r.compact && l.marked == r.marked
    }

    var body: some View {
        HStack(spacing: 8) {
            FaviconView(tab: tab)
            Text(tab.title)
                .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                .lineLimit(1)
                .foregroundStyle(tab.isHibernated && !selected ? .secondary : .primary)
            Spacer(minLength: 0)
            if tab.isPlayingAudio || tab.isMuted {
                Button { tab.setMuted(!tab.isMuted) } label: {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tab.isMuted ? LocalizedStringKey("Unmute tab") : "Mute tab")
                .accessibilityLabel(tab.isMuted ? LocalizedStringKey("Unmute tab") : "Mute tab")
            }
            if inSplit {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if hover || selected {
                CloseTabButton(iconSize: 9, visible: 16) { b.close(tab) }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: compact ? 28 : 34)
        .overlay(alignment: .leading) {
            if grouped, let groupTint {
                Capsule().fill(groupTint).frame(width: 2.5).padding(.vertical, 7).offset(x: -6)
            }
        }
        .padding(.leading, grouped ? 10 : 0)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.white.opacity(scheme == .dark ? 0.12 : 0.75) : Color.primary.opacity(hover ? 0.06 : 0))
                .shadow(color: .black.opacity(selected ? 0.07 : 0), radius: 1, y: 0.5)
        }
        .overlay {
            if marked {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { b.click(tab) }
        .onHover { hover = $0 }
        .contextMenu { TabMenu(tab: tab) }
        .draggable(b.dragPayload(for: tab)) {
            Label(tab.title, systemImage: "globe").padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { items, location in
            let h: CGFloat = compact ? 28 : 34
            let placement: BrowserState.DropPlacement = location.y < h * 0.28 ? .before : (location.y > h * 0.72 ? .after : .group)
            return b.handleDrop(items, on: tab, placement: placement, pinned: false)
        }
        .tabPreview(tab, edge: Settings.shared.sidebarSide == .left ? .trailing : .leading)
        .overlay(MiddleClick { b.close(tab) })
    }
}

struct PinnedGrid: View {
    @Environment(BrowserState.self) var b

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
            ForEach(b.pinnedTabs) { t in PinnedTile(tab: t, browser: b, selected: b.selectedID == t.id).equatable() }
        }
        .dropDestination(for: String.self) { items, _ in b.handleDrop(items, before: nil, pinned: true) }
    }
}

struct PinnedTile: View, Equatable {
    var tab: Tab
    let browser: BrowserState
    let selected: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    private var b: BrowserState { browser }

    static func == (l: PinnedTile, r: PinnedTile) -> Bool {
        l.tab === r.tab && l.browser === r.browser && l.selected == r.selected
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Color.white.opacity(scheme == .dark ? 0.14 : 0.8) : Color.primary.opacity(hover ? 0.1 : 0.06))
            .frame(height: 40)
            .overlay(FaviconView(tab: tab, size: 18))
            .overlay(alignment: .topTrailing) {
                if tab.isPlayingAudio || tab.isMuted {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 8)).foregroundStyle(.secondary).padding(4)
                }
            }
            .overlay {
                if b.marked.contains(tab.id) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.accentColor, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { b.click(tab) }
            .onHover { hover = $0 }
            .contextMenu { TabMenu(tab: tab) }
            .draggable(b.dragPayload(for: tab))
            .dropDestination(for: String.self) { items, _ in b.handleDrop(items, before: tab, pinned: true) }
            .tabPreview(tab, edge: Settings.shared.sidebarSide == .left ? .trailing : .leading)
    }
}

struct TabMenu: View {
    var tab: Tab
    @Environment(BrowserState.self) var b

    var body: some View {
        let targets = b.actionTabs(for: tab)
        if targets.count > 1 {
            ManyTabsMenu(tabs: targets)
        } else {
            OneTabMenu(tab: tab)
        }
    }
}

/// The menu of one tab.
struct OneTabMenu: View {
    var tab: Tab
    @Environment(BrowserState.self) var b
    @Bindable private var s = Settings.shared

    var body: some View {
        Button(tab.isPinned ? LocalizedStringKey("Unpin Tab") : "Pin Tab") { b.togglePin(tab) }
        Button("Duplicate Tab") { b.duplicate(tab) }
        if tab.groupID != nil {
            Button("Remove from Group") { b.removeFromGroup(tab) }
        } else if !tab.isPinned {
            Button("Add to New Group") { b.newGroup(with: tab) }
        }
        MoveToGroupMenu(tabs: [tab])
        if let host = tab.host {
            Button(s.isGroupException(host) ? LocalizedStringKey("Allow Grouping This Site") : "Never Group This Site") {
                s.setGroupException(host, !s.isGroupException(host))
                BrowserState.groupingChanged()
            }
        }
        Button(tab.isMuted ? LocalizedStringKey("Unmute Tab") : "Mute Tab") { tab.setMuted(!tab.isMuted) }
        if b.selectedID != tab.id {
            if b.splitID == tab.id {
                Button("Close Split View") { b.closeSplit() }
            } else {
                Button("Open in Split View") { b.openSplit(tab) }
            }
        }
        MoveToWindowMenu(tabs: [tab], group: nil)
        Divider()
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url?.absoluteString ?? "", forType: .string)
        }
        .disabled(tab.url == nil)
        Button(Bookmarks.shared.contains(tab.url) ? LocalizedStringKey("Remove Bookmark") : "Add Bookmark") {
            Bookmarks.shared.toggle(url: tab.url, title: tab.title)
        }
        .disabled(tab.url == nil)
        Button("Reload Tab") { tab.reload() }
        if !tab.isHibernated && !tab.isSelected {
            Button("Hibernate Tab") { tab.hibernate() }
            if tab.isPinned, let home = tab.pinnedHome, home != tab.url {
                Button("Back to Pinned Address") { tab.load(home) }
            }
        }
        SortTabsMenu()
        Divider()
        Button("Close Tab") { b.close(tab) }
        Button("Close Other Tabs") { b.closeOthers(tab) }
        Button("Close Duplicate Tabs") { b.closeDuplicates() }.disabled(b.duplicateCount == 0)
        if Settings.shared.tabLayout != .vertical {
            Button("Close Tabs to the Right") { b.closeBelow(tab) }
        } else {
            Button("Close Tabs Below") { b.closeBelow(tab) }
        }
    }
}

/// The menu of several picked tabs.
struct ManyTabsMenu: View {
    var tabs: [Tab]
    @Environment(BrowserState.self) var b

    var body: some View {
        Text(String(format: L("%d Tabs"), tabs.count))
        Button("Add to New Group") { b.group(tabs) }
        MoveToGroupMenu(tabs: tabs)
        if tabs.contains(where: { !$0.isPinned }) {
            Button("Pin Tabs") { b.setPinned(tabs, true) }
        } else {
            Button("Unpin Tabs") { b.setPinned(tabs, false) }
        }
        MoveToWindowMenu(tabs: tabs, group: nil)
        Button("Hibernate Tabs") { for t in tabs where !t.isSelected { t.hibernate() } }
        Divider()
        Button(String(format: L("Close %d Tabs"), tabs.count)) { b.close(tabs) }
        Button("Deselect Tabs") { b.marked = [] }
    }
}

/// Moves tabs into one of this window's groups.
struct MoveToGroupMenu: View {
    var tabs: [Tab]
    @Environment(BrowserState.self) var b

    var body: some View {
        let others = b.groups.filter { g in tabs.contains { $0.groupID != g.id } }
        if !others.isEmpty {
            Menu("Move to Group") {
                ForEach(others) { g in Button(g.name) { b.move(tabs, toGroup: g.id) } }
            }
        }
    }
}

/// Sorts this window's tabs.
struct SortTabsMenu: View {
    @Environment(BrowserState.self) var b

    var body: some View {
        Menu("Sort Tabs") {
            ForEach(BrowserState.TabSort.allCases) { o in Button(o.label) { b.sortTabs(by: o) } }
        }
    }
}

/// Moves tabs, or a whole group, to another window or profile.
struct MoveToWindowMenu: View {
    var tabs: [Tab]
    var group: TabGroup?
    @Environment(BrowserState.self) var b
    @Environment(\.openWindow) private var openWindow
    private var s = Settings.shared

    init(tabs: [Tab], group: TabGroup?) {
        self.tabs = tabs
        self.group = group
    }

    var body: some View {
        if !b.isPrivate {
            let others = WindowRegistry.shared.destinations(from: b)
            Menu(group == nil ? "Move to Window" : "Move Group to Window") {
                Button("New Window") { toNewWindow(profile: b.profileID) }
                if !others.isEmpty { Divider() }
                ForEach(Array(others.enumerated()), id: \.offset) { _, w in
                    Button(Self.label(w)) { b.move(tabs, group: group, to: w) }
                }
                let profiles = profileChoices(others)
                if !profiles.isEmpty {
                    Divider()
                    ForEach(profiles, id: \.id) { p in
                        Button(String(format: L("New Window in %@"), p.name)) { toNewWindow(profile: p.id) }
                    }
                }
            }
        }
    }

    /// Profiles (and the main one) without a window of their own, other than this window's.
    private func profileChoices(_ open: [BrowserState]) -> [(id: UUID?, name: String)] {
        let all: [(id: UUID?, name: String)] = [(nil, L("Main Profile"))] + s.profiles.map { ($0.id, $0.name) }
        return all.filter { p in p.id != b.profileID && !open.contains { $0.profileID == p.id } }
    }

    private func toNewWindow(profile: UUID?) {
        b.prepareMove(tabs, group: group, profile: profile)
        if let profile { openWindow(id: "profile", value: profile) } else { openWindow(id: "main") }
    }

    /// "Window with “Rome – Wikipedia” (4 tabs)", and the profile when it has one.
    static func label(_ w: BrowserState) -> String {
        let name = w.current?.title ?? "Tacet"
        let title = w.tabs.count == 1 ? String(format: L("Window with “%@” (1 tab)"), name)
            : String(format: L("Window with “%@” (%d tabs)"), name, w.tabs.count)
        return w.profile.map { "\(title) — \($0.name)" } ?? title
    }
}

/// What a group's menu offers, in the sidebar and the top bar.
struct GroupMenu: View {
    let group: TabGroup
    @Environment(BrowserState.self) var b
    @Bindable private var s = Settings.shared

    var body: some View {
        Button("New Tab in Group") { b.newTab(inGroup: group.id) }
        Menu("Colour") {
            ForEach(0..<TabGroup.colors.count, id: \.self) { i in
                Button { b.setColor(group.id, i) } label: { Text(GroupHeader.colorNames[i]) }
            }
        }
        Button(group.collapsed ? "Expand Group" : "Collapse Group") { b.toggleCollapsed(group.id) }
        MoveToWindowMenu(tabs: b.tabs(in: group), group: group)
        if let site = group.site {
            Button("Never Group This Site") {
                s.setGroupException(site, true)
                BrowserState.groupingChanged()
            }
        }
        Divider()
        Button("Ungroup Tabs") { b.ungroup(group.id) }
        if !b.isPrivate {
            Button("Save and Close Group") { b.saveAndClose(group.id) }
        }
        Button("Close Group") { b.closeGroup(group.id) }
    }
}

/// Says how many tabs repeat another tab's address, with a button to close them.
struct DuplicatesRow: View {
    let count: Int
    @Environment(BrowserState.self) var b

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.on.square.dashed").font(.system(size: 11))
            Text(count == 1 ? L("1 duplicate tab") : String(format: L("%d duplicate tabs"), count))
                .font(.system(size: 11.5)).lineLimit(1)
            Spacer(minLength: 4)
            Button("Close") { withAnimation(.easeOut(duration: 0.15)) { b.closeDuplicates() } }
                .buttonStyle(.link).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.04)))
        .help("Tabs that show the same address as another tab")
    }
}

/// Groups put away with Save and Close Group, to open again.
struct SavedGroupsSection: View {
    @Environment(BrowserState.self) var b
    private var saved = SavedGroups.shared
    @State private var expanded = false

    var body: some View {
        if !saved.items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
                        Text("Saved Groups").font(.system(size: 11.5, weight: .semibold))
                        Text("\(saved.items.count)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    ForEach(saved.items) { g in SavedGroupRow(group: g) }
                }
            }
            .padding(.top, 8)
        }
    }
}

struct SavedGroupRow: View {
    let group: SavedGroup
    @Environment(BrowserState.self) var b
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(TabGroup.colors[group.color % TabGroup.colors.count]).frame(width: 8, height: 8)
            Text(group.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(group.tabs.count)").font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.leading, 12)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { b.open(group) }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open Group") { b.open(group) }
            Button("Delete Saved Group") { SavedGroups.shared.remove(group.id) }
        }
        .help(group.tabs.map(\.title).joined(separator: "\n"))
    }
}

struct SidebarFooter: View {
    let showsDownloads: Bool
    @Environment(BrowserState.self) var b
    private var blocker = ContentBlocker.shared
    private var updates = UpdateChecker.shared
    @Bindable private var s = Settings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 2) {
            IconButton(systemName: "storefront", help: "Tacet Plugins (⇧⌘P)") { openWindow(id: "plugins") }
            IconButton(systemName: "books.vertical", help: "History and bookmarks (⌘Y)") {
                LibraryView.requestedSection = .history
                openWindow(id: "library")
            }
            if showsDownloads { DownloadsButton() }
            if showsDownloads { AssistantButton() }
            Spacer()
            if s.adBlock {
                // Short ("256k"), so it never wraps when the footer is crowded; the full number is in the tooltip.
                Label(Self.short(blocker.ruleCount), systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help("Tacet Shield is on with \(blocker.ruleCount.formatted()) rules")
            }
            Spacer()
            if let r = updates.available {
                Button { openWindow(id: "update") } label: {
                    Text("Update").font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help(String(format: L("%@ is available."), r.name))
            }
            IconButton(systemName: "eyeglasses", help: "New private window (⇧⌘N)") { openWindow(id: "private") }
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
    }
}

extension SidebarFooter {
    static func short(_ n: Int) -> String {
        n >= 10_000 ? "\(n / 1000)k" : n.formatted()
    }
}

// MARK: - Horizontal tabs

struct TabStrip: View {
    /// Compact: the strip shares the toolbar row and the selected tab shows the address.
    var compact = false
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared

    var body: some View {
        GeometryReader { geo in
            let pinned = b.pinnedTabs.count
            let visible = b.regularTabs.filter { t in !(b.groups.first { $0.id == t.groupID }?.collapsed ?? false) }
            let regular = max(1, visible.count + b.groups.count)
            let free = geo.size.width - 16 - CGFloat(pinned) * 40 - 34 - (compact ? 120 : 0)
            let width = min(240, max(compact ? 90 : 110, free / CGFloat(regular) - 4))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(stripItems) { item in
                        switch item {
                        case .tab(let t):
                            chip(t, width)
                        case .group(let g, let members):
                            HStack(spacing: 0) {
                                GroupChip(group: g, count: members.count)
                                if !g.collapsed {
                                    ForEach(Array(members.enumerated()), id: \.element.id) { i, t in
                                        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 16)
                                            .opacity(t.id == b.selectedID || (i > 0 && members[i - 1].id == b.selectedID) ? 0 : 1)
                                        chip(t, width)
                                    }
                                }
                            }
                            .padding(2)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(g.tint.opacity(0.35), lineWidth: 1))
                        }
                    }
                    IconButton(systemName: "plus", help: "New tab (⌘T)") { b.newTabWithPalette() }
                    if b.duplicateCount > 0 {
                        Button { withAnimation(.easeOut(duration: 0.15)) { b.closeDuplicates() } } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.on.square.dashed")
                                Text("\(b.duplicateCount)")
                            }
                                .font(.system(size: 11, weight: .medium))
                                .fixedSize()
                                .padding(.horizontal, 7).frame(height: 24)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(b.duplicateCount == 1 ? L("1 duplicate tab") + " · " + L("Close Duplicate Tabs")
                              : String(format: L("%d duplicate tabs"), b.duplicateCount) + " · " + L("Close Duplicate Tabs"))
                    }
                }
                .padding(.horizontal, compact ? 2 : 8)
                // The strip's empty part and the gaps between tabs move the window, like a title bar: in the
                // compact layout this row is most of the window's top.
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .leading)
                .background(WindowDragArea())
                .background(WheelScrollsSideways())
            }
        }
        .frame(height: 34)
        .padding(.bottom, compact ? 0 : 4)
    }
}

enum StripItem: Identifiable {
    case tab(Tab)
    case group(TabGroup, [Tab])
    var id: String {
        switch self {
        case .tab(let t): t.id.uuidString
        case .group(let g, _): "g" + g.id.uuidString
        }
    }
}

extension TabStrip {
    /// Tabs in order, with each group gathered into one folder-like item.
    var stripItems: [StripItem] {
        var out: [StripItem] = []
        var seen = Set<UUID>()
        for t in b.tabs {
            if !t.isPinned, let gid = t.groupID, let g = b.groups.first(where: { $0.id == gid }) {
                if seen.insert(gid).inserted { out.append(.group(g, b.tabs(in: g))) }
            } else {
                out.append(.tab(t))
            }
        }
        return out
    }

    func chip(_ t: Tab, _ width: CGFloat) -> some View {
        let selected = t.id == b.selectedID
        let selectedWide = compact && selected
        return TabChip(tab: t, browser: b, selected: selected, alwaysShowTitles: s.alwaysShowTitles,
                       width: t.isPinned ? 36 : (selectedWide ? min(420, max(220, width + 120)) : width), compact: compact,
                       marked: b.marked.contains(t.id))
            .equatable()
    }
}

/// The folder of a tab group in the top bar: "Google 3 ›" when closed.
struct GroupChip: View {
    let group: TabGroup
    let count: Int
    @Environment(BrowserState.self) var b
    @State private var hover = false
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        HStack(spacing: 6) {
            Text(group.name).font(.system(size: 12.5, weight: .bold)).lineLimit(1)
            Text("\(count)").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
            if group.collapsed {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.1 : (group.collapsed ? 0.06 : 0))))
        .contentShape(Rectangle())
        // One gesture, read from the click itself: waiting to see whether a double-click follows would hold
        // the first click back by the double-click interval. A second click undoes the fold and renames instead.
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                withAnimation(.easeOut(duration: 0.2)) { b.toggleCollapsed(group.id) }
                startRename()
            } else {
                withAnimation(.easeOut(duration: 0.2)) { b.toggleCollapsed(group.id) }
            }
        }
        .onHover { hover = $0 }
        .popover(isPresented: $renaming, arrowEdge: .bottom) {
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .padding(10)
                .onSubmit { commitRename() }
                .onExitCommand { renaming = false }
        }
        .contextMenu {
            Button("Rename Group…") { startRename() }
            GroupMenu(group: group)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let last = b.tabs(in: group).last else { return false }
            return b.handleDrop(items, on: last, placement: .group, pinned: false)
        }
        .help(L("Click to collapse, double-click to rename"))
    }

    private func startRename() {
        name = group.name
        renaming = true
    }

    private func commitRename() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { b.renameGroup(group.id, trimmed) }
        renaming = false
    }
}

/// Safari's compact layout: navigation, tabs and the address in one row.
struct CompactBar: View {
    @Environment(BrowserState.self) var b

    var body: some View {
        HStack(spacing: 4) {
            if !b.isFullScreen { Spacer().frame(width: 72) }
            if let tab = b.current { NavButtons(tab: tab) }
            TabStrip(compact: true)
            if let p = b.profile { ProfileBadge(profile: p, compact: true).fixedSize() }
            SpaceMenuButton()
            if let tab = b.current {
                ExtensionButtons(tab: tab)
                ExtensionsMenuButton(tab: tab)
                ShieldButton(tab: tab)
                DownloadsButton()
                AssistantButton()
                PageMenu(tab: tab)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(WindowDragArea())
    }
}

/// Like `TabRow`, takes plain values so only the chips that change are redrawn.
struct TabChip: View, Equatable {
    var tab: Tab
    let browser: BrowserState
    let selected: Bool
    let alwaysShowTitles: Bool
    let width: CGFloat
    var compact = false
    var marked = false
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    private var b: BrowserState { browser }

    static func == (l: TabChip, r: TabChip) -> Bool {
        l.tab === r.tab && l.browser === r.browser && l.selected == r.selected
            && l.alwaysShowTitles == r.alwaysShowTitles && l.width == r.width && l.compact == r.compact && l.marked == r.marked
    }

    var body: some View {
        let showsAddress = compact && selected && !tab.isPinned
        HStack(spacing: 6) {
            if showsAddress && !alwaysShowTitles && tab.url != nil {
                Image(systemName: tab.url?.scheme == "https" ? "lock.fill" : "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                FaviconView(tab: tab, size: 14)
            }
            if !tab.isPinned {
                Text(showsAddress && !alwaysShowTitles ? (tab.url.map { InputResolver.displayHost($0) } ?? L("Search or enter address")) : tab.title)
                    .font(.system(size: 12, weight: showsAddress ? .medium : .regular)).lineLimit(1)
                    .foregroundStyle(tab.isHibernated && !selected ? .secondary : .primary)
                Spacer(minLength: 0)
                if tab.isPlayingAudio || tab.isMuted {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .onTapGesture { tab.setMuted(!tab.isMuted) }
                }
                if hover || selected {
                    CloseTabButton(iconSize: 8, visible: 14) { b.close(tab) }
                }
            }
        }
        .padding(.horizontal, tab.isPinned ? 0 : 9)
        .frame(width: width, height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.white.opacity(scheme == .dark ? 0.12 : 0.75) : Color.primary.opacity(hover ? 0.07 : 0.03)))
        .overlay(alignment: .bottom) {
            if showsAddress && tab.isLoading {
                LoadingLine(load: tab.load).padding(.horizontal, 6)
            }
        }
        .overlay {
            if marked {
                RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let mods = BrowserState.clickModifiers
            if showsAddress && !mods.contains(.command) && !mods.contains(.shift) {
                b.showPalette(tab.url?.absoluteString)
            } else {
                b.click(tab, modifiers: mods)
            }
        }
        .onHover { hover = $0 }
        .contextMenu { TabMenu(tab: tab) }
        .draggable(b.dragPayload(for: tab))
        .dropDestination(for: String.self) { items, location in
            let placement: BrowserState.DropPlacement = tab.isPinned ? .before
                : (location.x < width * 0.25 ? .before : (location.x > width * 0.75 ? .after : .group))
            return b.handleDrop(items, on: tab, placement: placement, pinned: tab.isPinned)
        }
        .tabPreview(tab, edge: .bottom)
        .overlay(MiddleClick { b.close(tab) })
    }
}

/// The ✕ on a tab. It keeps its small look but takes clicks from a wider area around it,
/// without changing the row's layout.
struct CloseTabButton: View {
    let iconSize: CGFloat
    let visible: CGFloat
    let action: () -> Void
    @State private var hover = false
    private let slop: CGFloat = 5

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: iconSize, weight: .bold))
                .frame(width: visible, height: visible)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.12 : 0)))
                .padding(slop)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hover ? .primary : .secondary)
        .onHover { hover = $0 }
        .padding(-slop)
        .help("Close tab (⌘W)")
    }
}

/// Closes a tab with a click of the mouse's middle button (the scroll wheel), as in other browsers. It takes only
/// that click: every other click goes through to the tab underneath.
struct MiddleClick: NSViewRepresentable {
    let action: () -> Void

    final class Catcher: NSView {
        var action: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent, e.type == .otherMouseDown || e.type == .otherMouseUp, e.buttonNumber == 2 else { return nil }
            return super.hitTest(point)
        }
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action() } else { super.otherMouseUp(with: event) }
        }
    }

    func makeNSView(context: Context) -> Catcher {
        let v = Catcher()
        v.action = action
        return v
    }

    func updateNSView(_ v: Catcher, context: Context) { v.action = action }
}
