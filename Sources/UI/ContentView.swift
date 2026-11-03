import SwiftUI
import WebKit

/// Keeps one BrowserState alive for the window. It publishes nothing: views observe the state itself.
final class BrowserHolder: ObservableObject {
    let browser: BrowserState
    init(_ browser: BrowserState) { self.browser = browser }
}

extension FocusedValues {
    @Entry var browser: BrowserState?
}

struct ContentView: View {
    /// `@StateObject` builds the window's state once; `@State` would build a throwaway BrowserState
    /// (restoring the session, registering the window) every time SwiftUI re-creates this view.
    @StateObject private var holder: BrowserHolder
    private var browser: BrowserState { holder.browser }
    private var settings = Settings.shared
    @Environment(\.openWindow) private var openWindow
    static var onboardingShown = false
    static var updateChecked = false
    static var profileAsked = false

    init(isPrivate: Bool, profileID: UUID? = nil) {
        _holder = StateObject(wrappedValue: BrowserHolder(BrowserState(isPrivate: isPrivate, profileID: profileID)))
    }

    var body: some View {
        Group {
            if WebApp.isActive { WebAppLayout() } else { BrowserLayout() }
        }
            .environment(browser)
            .tint(settings.accent)
            .focusedSceneValue(\.browser, browser)
            .background(WindowAccessor { browser.attach($0) })
            .frame(minWidth: 640, minHeight: 420)
            .ignoresSafeArea()
            .onAppear {
                // Lets opening rules open a private or profile window for a link.
                WindowRegistry.shared.openWindow = { id, profile in
                    if id == "profile", let profile { openWindow(id: id, value: profile) } else { openWindow(id: id) }
                }
                guard !browser.isPrivate, !WebApp.isActive else { return }
                // The first window of a fresh start asks for a profile, unless it reopened the last session or a link.
                if !ContentView.profileAsked {
                    ContentView.profileAsked = true
                    if settings.onboarded, settings.askProfileAtLaunch, !settings.profiles.isEmpty, !browser.restored,
                       browser.profileID == nil, !browser.tabs.contains(where: { $0.url != nil }) {
                        browser.showProfilePicker = true
                    }
                }
                // Saved windows reopen one at a time: each one opens the next, since macOS can drop
                // windows asked for all at once.
                if Session.shared.hasPendingWindows {
                    DispatchQueue.main.async { openWindow(id: "main") }
                }
                if !ContentView.updateChecked && settings.checkUpdates {
                    ContentView.updateChecked = true
                    UpdateChecker.shared.check {
                        if UpdateChecker.shared.announceable != nil && settings.onboarded { openWindow(id: "update") }
                    }
                }
                if !settings.onboarded && !ContentView.onboardingShown {
                    ContentView.onboardingShown = true
                    browser.paletteVisible = false
                    browser.showOnboarding = true
                } else if settings.onboarded && settings.welcomedVersion != UpdateChecker.currentVersion && !ContentView.onboardingShown {
                    // Once per update, for people coming from an earlier version.
                    ContentView.onboardingShown = true
                    settings.aiIntroduced = true
                    if WhatsNew.pages(since: settings.welcomedVersion).isEmpty { settings.welcomedVersion = UpdateChecker.currentVersion } else { browser.showWhatsNew = true }
                } else if settings.onboarded && !settings.aiIntroduced && settings.aiEnabled {
                    settings.aiIntroduced = true
                } else if settings.onboarded && !settings.aiIntroduced && !ContentView.onboardingShown {
                    // People who set Tacet up before 1.5.4 hear about the assistant once.
                    ContentView.onboardingShown = true
                    browser.showAssistantIntro = true
                }
            }
            .sheet(isPresented: Bindable(browser).showOnboarding) { OnboardingView() }
            .sheet(isPresented: Bindable(browser).showProfilePicker) { ProfilePicker() }
            .sheet(isPresented: Bindable(browser).showWhatsNew, onDismiss: { settings.welcomedVersion = UpdateChecker.currentVersion }) { WhatsNewView() }
            .sheet(isPresented: Bindable(browser).showAssistantIntro, onDismiss: { settings.aiIntroduced = true }) { AssistantIntro() }
            .sheet(isPresented: Bindable(browser).customizingSite) {
                if let tab = browser.current, tab.host != nil { SiteCustomizer(host: tab.host, tab: tab) }
            }
            .sheet(isPresented: Bindable(browser).showInstallApp) {
                if let tab = browser.current { InstallAppSheet(tab: tab) }
            }
    }
}

// MARK: - Layout

struct BrowserLayout: View {
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared
    /// The sidebar width while its edge is dragged, saved to settings only when the drag ends.
    @State private var dragWidth: Double?

    private var vertical: Bool { s.tabLayout == .vertical }
    private var sidebarWidth: Double { dragWidth ?? s.sidebarWidth }
    private var sidebarShown: Bool { vertical && b.sidebarVisible }
    private var left: Bool { s.sidebarSide == .left }
    /// Navigation and the address live in the sidebar only when it sits next to the traffic lights.
    private var controlsInSidebar: Bool { sidebarShown && left && s.addressInSidebar }

    var body: some View {
        ZStack {
            ChromeBackground()
            GeometryReader { geo in
                HStack(spacing: 0) {
                    layout
                    if b.assistantVisible && s.aiEnabled {
                        // The panel can take a little less than half the window.
                        AssistantPanel(maxWidth: geo.size.width * 0.45).transition(.move(edge: .trailing))
                    }
                }
            }
            if b.assistantVisible && b.assistantExpanded && s.aiEnabled {
                AssistantFullView().transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            if b.paletteVisible {
                CommandPalette().transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            if b.locked { PrivateLockView() }
        }
        .animation(.easeOut(duration: 0.18), value: b.sidebarVisible)
        .animation(.easeOut(duration: 0.15), value: b.paletteVisible)
        .animation(.easeOut(duration: 0.15), value: b.peekSidebar)
        .animation(.easeOut(duration: 0.18), value: b.assistantVisible)
        .animation(.easeOut(duration: 0.2), value: b.assistantExpanded)
        .animation(.easeOut(duration: 0.25), value: b.focusMode)
    }

    @ViewBuilder private var layout: some View {
        ZStack {
            if #available(macOS 15.0, *) { PageTranslationHost() }
            if b.focusMode {
                FocusLayout()
            } else if vertical {
                HStack(spacing: 0) {
                    if sidebarShown && left {
                        Sidebar(showsControls: controlsInSidebar).frame(width: sidebarWidth)
                        ResizeHandle(side: .left, width: $dragWidth)
                    }
                    MainColumn(toolbar: !controlsInSidebar,
                               trafficSpace: !(sidebarShown && left),
                               leadingFlush: sidebarShown && left,
                               trailingFlush: sidebarShown && !left)
                    if sidebarShown && !left {
                        ResizeHandle(side: .right, width: $dragWidth)
                        Sidebar(showsControls: false).frame(width: sidebarWidth)
                    }
                }
                if !b.sidebarVisible { PeekSidebar() }
            } else if s.tabLayout == .compact {
                VStack(spacing: 0) {
                    CompactBar()
                    MainColumn(toolbar: false, trafficSpace: false, leadingFlush: false, trailingFlush: false)
                }
            } else {
                VStack(spacing: 0) {
                    Toolbar(trafficSpace: true)
                    TabStrip()
                    MainColumn(toolbar: false, trafficSpace: false, leadingFlush: false, trailingFlush: false)
                }
            }
        }
    }
}

/// Focus Mode: the page alone, with a way out that appears when the pointer reaches the top of the window.
struct FocusLayout: View {
    @Environment(BrowserState.self) var b
    @State private var showExit = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                WindowDragArea()
                if showExit {
                    Button { b.focusMode = false } label: {
                        Label("Exit Focus Mode", systemImage: "arrow.down.right.and.arrow.up.left").font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .help("Exit Focus Mode (⇧⌘J)")
                    .transition(.opacity)
                }
            }
            .frame(height: 30)
            .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { showExit = inside } }
            PageArea().padding([.horizontal, .bottom], 6)
        }
    }
}

struct MainColumn: View {
    let toolbar: Bool
    let trafficSpace: Bool
    let leadingFlush: Bool
    let trailingFlush: Bool
    @Bindable var s = Settings.shared

    var body: some View {
        let inset: CGFloat = s.insetContent ? 8 : 0
        VStack(spacing: 0) {
            if toolbar { Toolbar(trafficSpace: trafficSpace) }
            // The gap above the page belongs to the bar over it, so it moves the window too.
            if !toolbar && inset > 0 { WindowDragArea().frame(height: inset) }
            PageArea()
                .padding(.bottom, inset)
                .padding(.leading, leadingFlush ? 0 : inset)
                .padding(.trailing, trailingFlush ? 0 : inset)
        }
    }
}

struct PageArea: View {
    @Environment(BrowserState.self) var b

    var body: some View {
        HStack(spacing: 6) {
            if let tab = b.current { TabPane(tab: tab, isSplit: false).id(tab.id) }
            if let split = b.splitTab { TabPane(tab: split, isSplit: true).id(split.id) }
        }
        .overlay {
            if let preview = b.preview { LinkPreviewPanel(tab: preview).id(preview.id).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: b.preview?.id)
    }
}

/// A link opened over the page (⌥-click): the page stays behind it, dimmed, as it was.
struct LinkPreviewPanel: View {
    var tab: Tab
    @Environment(BrowserState.self) var b

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture { b.closePreview() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    FaviconView(tab: tab, size: 14)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(tab.title.isEmpty ? InputResolver.displayHost(tab.url) : tab.title)
                            .font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Text(InputResolver.displayHost(tab.url)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Side by Side") { b.splitPreview() }.help("Show it next to this page in split view")
                    Button("Open as Tab") { b.keepPreview() }.buttonStyle(.borderedProminent).help("Keep it as a tab (⌘↩)")
                    Button { b.closePreview() } label: { Label("Close", systemImage: "xmark").labelStyle(.iconOnly).font(.system(size: 11, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Close (Esc)")
                }
                .controlSize(.small)
                .padding(.horizontal, 12).frame(height: 40)
                Divider()
                ZStack {
                    if let wv = tab.webView { WebContainer(webView: wv, radius: 0) }
                    if tab.isLoading && tab.webView?.url == nil { ProgressView().controlSize(.small) }
                }
                .overlay(alignment: .top) { if tab.isLoading { LoadingLine(load: tab.load) } }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
            .padding(.horizontal, 48).padding(.vertical, 28)
        }
        .onAppear { tab.ensureWebView() }
    }
}

struct TabPane: View {
    var tab: Tab
    let isSplit: Bool
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared

    var body: some View {
        let r: CGFloat = s.insetContent ? s.cornerRadius : 0
        ZStack {
            if let wv = tab.webView {
                // The same view with or without a device size, so the web view never changes container.
                DeviceFrame(tab: tab) { WebContainer(webView: wv, radius: tab.device == nil ? r : 10) }
            }
            if let look = tab.sleepImage {
                // The page as it was, top-aligned, until it has loaded again.
                GeometryReader { geo in
                    Image(nsImage: look).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top).clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            if tab.isStartPage {
                StartPage(tab: tab).clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(s.insetContent ? 0.14 : 0), radius: 2.5, y: 1)
        )
        .overlay(alignment: .bottomLeading) {
            if s.statusBar, let link = tab.hoverURL { StatusBubble(text: link) }
        }
        .overlay(alignment: .topLeading) {
            if let menu = tab.loginMenu { LoginMenuView(tab: tab, menu: menu) }
        }
        .overlay(alignment: .top) { PullIndicator(pull: tab.pull) }
        .overlay(alignment: .top) {
            if tab.translating || tab.translatedFrom != nil || tab.translationError != nil { TranslationBar(tab: tab) }
        }
        .animation(.easeOut(duration: 0.2), value: tab.translating)
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                if tab.insecureWarning { InsecurePasswordBanner(tab: tab) }
                if let help = tab.passkeyHelp { PasskeyBanner(tab: tab, help: help) }
                if !tab.draftOffer.isEmpty { DraftBanner(tab: tab, drafts: tab.draftOffer) }
                if let pending = tab.pendingSave { SavePasswordBanner(tab: tab, pending: pending) }
            }
            .animation(.easeOut(duration: 0.2), value: tab.pendingSave)
            .animation(.easeOut(duration: 0.2), value: tab.passkeyHelp)
            .animation(.easeOut(duration: 0.2), value: tab.draftOffer)
            .animation(.easeOut(duration: 0.2), value: tab.insecureWarning)
        }
        .overlay(alignment: .bottomTrailing) {
            if tab.isReader && !tab.isPrivate { ReaderSaveButton(tab: tab) }
        }
        .overlay(alignment: .topTrailing) {
            if isSplit {
                SplitHeader(tab: tab)
            } else if b.findVisible {
                FindBar(tab: tab)
            }
        }
    }
}

// MARK: - AppKit bridges

/// Hosts a tab's web view, clipped to the content corner radius.
struct WebContainer: NSViewRepresentable {
    let webView: WKWebView
    let radius: CGFloat

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerCurve = .continuous
        host(in: v)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        v.layer?.cornerRadius = radius
        v.layer?.masksToBounds = radius > 0
        if webView.superview !== v { host(in: v) }
    }

    private func host(in v: NSView) {
        v.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = v.bounds
        webView.autoresizingMask = [.width, .height]
        v.addSubview(webView)
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReaderView {
        let v = WindowReaderView()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ v: WindowReaderView, context: Context) {}
}

final class WindowReaderView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { self.onWindow?(window) }
    }
}

/// Empty chrome that drags the window, and zooms it on double-click, like a title bar.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        /// Hands the drag to macOS, so dragging to a screen edge or corner tiles the window as it does for other
        /// apps. Browser windows aren't movable from anywhere else (the page, the tabs), so this is the only way in.
        private func moveWindow(from down: NSEvent) {
            guard let window else { return }
            window.isMovable = true
            window.performDrag(with: down)
            window.isMovable = false
        }

        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2 else {
                moveWindow(from: event)
                return
            }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
            case "Minimize": window?.performMiniaturize(nil)
            case "None": break
            default: window?.performZoom(nil)
            }
        }
    }
}

// MARK: - Chrome

struct ChromeBackground: View {
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared

    var body: some View {
        ZStack {
            switch s.chromeStyle {
            case .translucent:
                VisualEffect(material: .sidebar)
            case .solid:
                Color(nsColor: .windowBackgroundColor)
            case .tinted:
                VisualEffect(material: .sidebar)
                s.accent.opacity(0.18)
            }
            if s.siteTint, let tab = b.current { SiteTint(tab: tab) }
            if b.isPrivate { Color(red: 0.36, green: 0.22, blue: 0.62).opacity(0.24) }
            if let p = b.profile { p.tint.opacity(0.1) }
        }
        .ignoresSafeArea()
    }
}

/// Washes the chrome with the page's theme colour.
struct SiteTint: View {
    var tab: Tab

    var body: some View {
        Group {
            if let c = tab.themeColor, !tab.isStartPage { Color(nsColor: c).opacity(0.22) } else { Color.clear }
        }
        .animation(.easeInOut(duration: 0.35), value: tab.themeColor)
    }
}

struct ResizeHandle: View {
    let side: SidebarSide
    @Binding var width: Double?
    @Bindable var s = Settings.shared
    @State private var start: Double?

    var body: some View {
        ZStack {
            Color.clear
            if !s.insetContent { Divider() }
        }
        .frame(width: s.insetContent ? 6 : 1)
        .contentShape(Rectangle().inset(by: -3))
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let base = start ?? s.sidebarWidth
                    if start == nil { start = base }
                    let delta = side == .left ? v.translation.width : -v.translation.width
                    width = min(420, max(180, base + delta))
                }
                .onEnded { _ in
                    if let width { s.sidebarWidth = width }
                    width = nil
                    start = nil
                }
        )
    }
}

/// With the sidebar hidden, hovering the window edge slides it in over the page.
struct PeekSidebar: View {
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared

    var body: some View {
        let left = s.sidebarSide == .left
        HStack(spacing: 0) {
            if !left { Spacer(minLength: 0) }
            if b.peekSidebar {
                Sidebar(showsControls: false)
                    .frame(width: s.sidebarWidth)
                    .background(
                        ZStack {
                            VisualEffect(material: .sidebar, blending: .withinWindow)
                            if b.isPrivate { Color.purple.opacity(0.15) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 16)
                    )
                    .padding(6)
                    .onHover { if !$0 { b.peekSidebar = false } }
                    .transition(.move(edge: left ? .leading : .trailing).combined(with: .opacity))
            } else {
                Color.clear
                    .frame(width: 5)
                    .contentShape(Rectangle())
                    .onHover { if $0 { b.peekSidebar = true } }
            }
            if left { Spacer(minLength: 0) }
        }
    }
}

// MARK: - Small shared views

struct IconButton: View {
    let systemName: String
    var help: String = ""
    var tint: Color?
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover && enabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? Color.secondary)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hover = $0 }
        .help(L(help))
        .accessibilityLabel(help.isEmpty ? systemName : String(L(help).prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces))
    }
}

struct FaviconView: View {
    var tab: Tab
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let img = tab.favicon {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else if tab.isLoading {
                ProgressView().controlSize(.mini).scaleEffect(size / 20)
            } else if tab.isStartPage {
                Image(systemName: "sparkle").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.tint).padding(1)
            } else {
                Image(systemName: "globe").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary).padding(1)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 5, style: .continuous))
        // Hibernated tabs show in grey until they wake up.
        .saturation(tab.isHibernated && tab.url != nil ? 0 : 1)
        .opacity(tab.isHibernated && tab.url != nil ? 0.55 : 1)
    }
}

struct StatusBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.08)))
            .frame(maxWidth: 520, alignment: .leading)
            .padding(8)
            .allowsHitTesting(false)
    }
}

struct SplitHeader: View {
    var tab: Tab
    @Environment(BrowserState.self) var b

    var body: some View {
        HStack(spacing: 2) {
            FaviconView(tab: tab, size: 13).padding(.leading, 8)
            Text(tab.title).font(.system(size: 11)).lineLimit(1).frame(maxWidth: 160)
            IconButton(systemName: "arrow.left.arrow.right", help: "Swap panes", size: 10) { b.swapSplit() }
            IconButton(systemName: "xmark", help: "Close split view", size: 10) { b.closeSplit() }
        }
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
        .padding(8)
    }
}

/// The arrow that appears while you pull a page down to reload it.
struct PullIndicator: View {
    var pull: PullToRefresh

    var body: some View {
        let p = pull.progress
        let ready = p >= 1
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 13, weight: .semibold))
            .rotationEffect(.degrees(Double(p) * 270))
            .foregroundStyle(ready ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .frame(width: 32, height: 32)
            .background(Circle().fill(ready ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial)))
            .overlay(Circle().trim(from: 0, to: p).stroke(.tint, lineWidth: 2).rotationEffect(.degrees(-90)).opacity(ready ? 0 : 1))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .scaleEffect(0.6 + 0.4 * p)
            .opacity(Double(min(1, p * 2.5)))
            .offset(y: -20 + 34 * p)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: ready)
            .allowsHitTesting(false)
    }
}


/// In Reader, a quiet button that saves the article to read offline.
struct ReaderSaveButton: View {
    var tab: Tab
    private var list = ReadingList.shared
    @State private var hover = false

    init(tab: Tab) { self.tab = tab }

    var body: some View {
        let source = tab.readerSource
        let saved = list.article(for: source) != nil
        let saving = source.map { list.saving.contains($0) } ?? false
        Button { tab.saveForOffline() } label: {
            HStack(spacing: 6) {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: saved ? "checkmark.circle.fill" : "arrow.down.circle")
                }
                Text(saving ? LocalizedStringKey("Saving…") : (saved ? "Saved for Offline" : "Save for Offline"))
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).frame(height: 30)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
            .opacity(hover || !saved ? 1 : 0.75)
        }
        .buttonStyle(.plain)
        .disabled(saving)
        .onHover { hover = $0 }
        .padding(16)
        .help(saved ? "Saved in the Reading List. Click to save it again." : "Saves the article with its images, to read without a connection")
    }
}

/// "Who's browsing?": the main profile and each one you made. Picking another opens its window in place of this one.
struct ProfilePicker: View {
    @Environment(BrowserState.self) var b
    @Environment(\.openWindow) private var openWindow
    @Bindable private var s = Settings.shared

    var body: some View {
        VStack(spacing: 18) {
            Text("Who's browsing?").font(.system(size: 22, weight: .bold))
            HStack(spacing: 14) {
                tile(name: L("Main Profile"), color: .accentColor) { b.showProfilePicker = false }
                ForEach(s.profiles) { p in
                    tile(name: p.name, color: p.tint) {
                        b.showProfilePicker = false
                        openWindow(id: "profile", value: p.id)
                        // This window was only the main profile's start page.
                        let window = b.window
                        DispatchQueue.main.async { window?.close() }
                    }
                }
            }
            Toggle("Ask every time Tacet opens", isOn: $s.askProfileAtLaunch).toggleStyle(.checkbox).font(.callout)
        }
        .padding(28)
        .frame(minWidth: 360)
    }

    private func tile(name: String, color: Color, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 52)).foregroundStyle(color)
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .frame(width: 104, height: 104)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
