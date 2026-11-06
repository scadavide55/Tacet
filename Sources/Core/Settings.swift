import SwiftUI
import WebKit

extension Notification.Name {
    static let settingChanged = Notification.Name("lumen.settingChanged")
}

// MARK: - Option types

enum ThemeMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { L(["system": "System", "light": "Light", "dark": "Dark"][rawValue]!) }
}

enum TabLayout: String, Codable, CaseIterable, Identifiable {
    case vertical, horizontal, compact
    var id: String { rawValue }
    var label: String { L(["vertical": "Sidebar", "horizontal": "Separate", "compact": "Compact"][rawValue]!) }
}

enum SidebarSide: String, Codable, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var label: String { L(self == .left ? "Left" : "Right") }
}

enum ChromeStyle: String, Codable, CaseIterable, Identifiable {
    case translucent, solid, tinted
    var id: String { rawValue }
    var label: String { L(["translucent": "Translucent", "solid": "Solid", "tinted": "Tinted"][rawValue]!) }
}

enum StartBackground: String, Codable, CaseIterable, Identifiable {
    case aurora, dusk, ocean, forest, ember, graphite, flow, accent, plain, image, video
    var id: String { rawValue }
    var label: String { L(["plain": "Plain", "flow": "Flow (animated)"][rawValue] ?? rawValue.capitalized) }
    var isGradient: Bool { ![.plain, .image, .video, .accent].contains(self) }
}

enum PopupMode: String, Codable, CaseIterable, Identifiable {
    case never, automatic, always
    var id: String { rawValue }
    var label: String { L(["never": "Never", "automatic": "Automatically", "always": "Always"][rawValue]!) }
}

enum NewTabPosition: String, Codable, CaseIterable, Identifiable {
    case afterCurrent, end
    var id: String { rawValue }
    var label: String { L(self == .end ? "At the end" : "Next to current tab") }
}

enum UserAgentMode: String, Codable, CaseIterable, Identifiable {
    case safari, custom
    var id: String { rawValue }
    var label: String { L(self == .safari ? "Safari (recommended)" : "Custom") }
}

enum SearchEngine: String, Codable, CaseIterable, Identifiable {
    case duckduckgo, google, bing, brave, startpage, ecosia, kagi, custom
    var id: String { rawValue }

    var name: String {
        switch self {
        case .duckduckgo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        case .brave: "Brave Search"
        case .startpage: "Startpage"
        case .ecosia: "Ecosia"
        case .kagi: "Kagi"
        case .custom: L("Custom")
        }
    }

    /// Search URL with `%s` standing for the query.
    var template: String {
        switch self {
        case .duckduckgo: "https://duckduckgo.com/?q=%s"
        case .google: "https://www.google.com/search?q=%s"
        case .bing: "https://www.bing.com/search?q=%s"
        case .brave: "https://search.brave.com/search?q=%s"
        case .startpage: "https://www.startpage.com/do/search?q=%s"
        case .ecosia: "https://www.ecosia.org/search?q=%s"
        case .kagi: "https://kagi.com/search?q=%s"
        case .custom: Settings.shared.customSearch
        }
    }

    /// Suggestion endpoint returning OpenSearch JSON (`["query", ["a", "b"]]`).
    var suggestTemplate: String? {
        switch self {
        case .duckduckgo: "https://duckduckgo.com/ac/?q=%s&type=list"
        case .google: "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"
        case .bing: "https://api.bing.com/osjson.aspx?query=%s"
        case .brave: "https://search.brave.com/api/suggest?q=%s"
        case .ecosia: "https://ac.ecosia.org/autocomplete?q=%s&type=list"
        default: nil
        }
    }
}

struct SearchShortcut: Codable, Identifiable, Hashable {
    var id = UUID()
    var keyword: String
    var name: String
    var template: String
}

/// A separate set of cookies, sign-ins and site data, for windows opened in it.
struct Profile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var color = 0
    /// Optional, so profiles saved before proxies existed read as before.
    var proxy: ProfileProxy?
    var tint: Color { TabGroup.colors[color % TabGroup.colors.count] }
}

/// Deleting a profile's cookies and site data.
enum ProfileCleanup {
    private static let key = "lumen.profilesToRemove"

    /// Erases the profile's data right away. WebKit only gives up the profile's folder once Tacet
    /// restarts, so removing the folder itself may wait until then.
    static func remove(_ id: UUID) {
        let store = WKWebsiteDataStore(forIdentifier: id)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            _ = store
            WKWebsiteDataStore.remove(forIdentifier: id) { error in
                if error != nil { DispatchQueue.main.async { pending.append(id.uuidString) } }
            }
        }
    }

    /// Removes folders left by profiles deleted last time. It runs once a page has loaded,
    /// because WebKit crashes when asked to remove a profile before it has started.
    static func finishPending(attempt: Int = 0) {
        let ids = pending.compactMap(UUID.init)
        guard !ids.isEmpty else { return }
        guard WindowRegistry.shared.browsers.contains(where: { $0.current?.webView != nil }) else {
            if attempt < 12 { DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finishPending(attempt: attempt + 1) } }
            return
        }
        pending = []
        for id in ids {
            WKWebsiteDataStore.remove(forIdentifier: id) { error in
                if error != nil { DispatchQueue.main.async { pending.append(id.uuidString) } }
            }
        }
    }

    private static var pending: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum MediaPermission {
    enum Kind: String {
        case camera, microphone, both

        init(_ type: WKMediaCaptureType) {
            switch type {
            case .camera: self = .camera
            case .microphone: self = .microphone
            default: self = .both
            }
        }

        var label: String { L(["camera": "camera", "microphone": "microphone", "both": "camera and microphone"][rawValue]!) }
    }

    static func key(host: String, kind: Kind) -> String { host.lowercased() + "|" + kind.rawValue }

    /// Splits a stored key back into its site and what it's for.
    static func parse(_ key: String) -> (host: String, kind: Kind)? {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = Kind(rawValue: parts[1]) else { return nil }
        return (parts[0], kind)
    }
}

/// How a site looks in Tacet: ready-made options, elements picked on the page to hide, and your own CSS and JavaScript.
struct SiteStyle: Codable, Identifiable, Hashable {
    enum Theme: String, Codable, CaseIterable { case site, dark }
    enum Font: String, Codable, CaseIterable { case site, system, serif, mono }
    enum Width: String, Codable, CaseIterable { case site, narrow, medium }

    var id = UUID()
    var host: String
    var css: String
    var enabled = true
    var theme = Theme.site
    var font = Font.site
    var width = Width.site
    var hideFloating = false
    var hideImages = false
    var reduceMotion = false
    /// CSS selectors of elements picked on the page to hide.
    var hidden: [String] = []
    /// Your own JavaScript, run in the page when it has loaded.
    var js = ""

    init(id: UUID = UUID(), host: String, css: String = "", enabled: Bool = true) {
        self.id = id
        self.host = host
        self.css = css
        self.enabled = enabled
    }

    // Styles saved before these options existed have only host, css and enabled.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        css = try c.decodeIfPresent(String.self, forKey: .css) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        theme = (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? .site
        font = (try? c.decodeIfPresent(Font.self, forKey: .font)) ?? .site
        width = (try? c.decodeIfPresent(Width.self, forKey: .width)) ?? .site
        hideFloating = try c.decodeIfPresent(Bool.self, forKey: .hideFloating) ?? false
        hideImages = try c.decodeIfPresent(Bool.self, forKey: .hideImages) ?? false
        reduceMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
        js = try c.decodeIfPresent(String.self, forKey: .js) ?? ""
    }

    /// "github.com" from "https://www.github.com/x".
    static func normalizedHost(_ raw: String) -> String {
        let r = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return (URL(string: r.contains("://") ? r : "https://" + r)?.host ?? r)
            .replacingOccurrences(of: "www.", with: "", options: .anchored)
    }

    func matches(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !self.host.isEmpty else { return false }
        return h == self.host || h.hasSuffix("." + self.host)
    }

    var isEmpty: Bool {
        theme == .site && font == .site && width == .site && !hideFloating && !hideImages && !reduceMotion
            && hidden.isEmpty && css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The dark theme, applied by the page script only to pages that aren't dark already.
    static let darkCSS = "html{filter:invert(.92) hue-rotate(180deg)!important;background:#fff!important}"
        + "img,video,picture,canvas,iframe,embed,object,[style*=\"background-image\"]{filter:invert(1) hue-rotate(180deg)!important}"

    /// Everything but the dark theme and your JavaScript, as one style sheet.
    var effectiveCSS: String {
        var parts: [String] = []
        switch font {
        case .site: break
        case .system: parts.append("body,body *:not(code):not(pre):not(kbd):not(samp){font-family:-apple-system,system-ui,sans-serif!important}")
        case .serif: parts.append("body,body *:not(code):not(pre):not(kbd):not(samp){font-family:'New York',ui-serif,Georgia,serif!important}")
        case .mono: parts.append("body,body *{font-family:ui-monospace,Menlo,monospace!important}")
        }
        switch width {
        case .site: break
        case .narrow: parts.append("body{max-width:760px!important;margin-left:auto!important;margin-right:auto!important}")
        case .medium: parts.append("body{max-width:1100px!important;margin-left:auto!important;margin-right:auto!important}")
        }
        if hideImages { parts.append("img,picture,video,svg image,[role=img]{visibility:hidden!important}") }
        if reduceMotion { parts.append("*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}") }
        if !hidden.isEmpty { parts.append(hidden.joined(separator: ",\n") + "{display:none!important}") }
        if !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(css) }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Persisted preference wrapper

/// Stores a Codable value in UserDefaults and reports reads and changes to the
/// enclosing `Settings` object, so a view only redraws for the preferences it reads.
@propertyWrapper
struct Pref<Value: Codable> {
    let key: String
    var value: Value

    init(wrappedValue: Value, _ key: String) {
        self.key = key
        if let data = UserDefaults.standard.data(forKey: "lumen." + key),
           let v = try? JSONDecoder().decode(Value.self, from: data) {
            value = v
        } else {
            value = wrappedValue
        }
    }

    @available(*, unavailable, message: "Pref can only be used inside Settings")
    var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    static subscript(
        _enclosingInstance s: Settings,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Settings, Value>,
        storage k: ReferenceWritableKeyPath<Settings, Pref<Value>>
    ) -> Value {
        get {
            s.registrar.access(s, keyPath: wrappedKeyPath)
            return s[keyPath: k].value
        }
        set {
            s.registrar.withMutation(of: s, keyPath: wrappedKeyPath) { s[keyPath: k].value = newValue }
            let key = s[keyPath: k].key
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "lumen." + key)
            }
            s.didChange(key)
        }
    }
}

// MARK: - Settings

/// Observable by hand rather than with `@Observable`, which can't be combined with the `@Pref` wrapper.
final class Settings: Observable {
    static let shared = Settings()
    fileprivate let registrar = ObservationRegistrar()

    // Appearance
    @Pref("theme") var theme = ThemeMode.system
    @Pref("accent") var accentHex = "#5E5CE6"
    @Pref("tabLayout") var tabLayout = TabLayout.vertical
    @Pref("sidebarSide") var sidebarSide = SidebarSide.left
    @Pref("chromeStyle") var chromeStyle = ChromeStyle.translucent
    @Pref("sidebarWidth") var sidebarWidth = 240.0
    @Pref("sidebarVisible") var sidebarVisible = true
    @Pref("addressInSidebar") var addressInSidebar = true
    @Pref("insetContent") var insetContent = true
    @Pref("cornerRadius") var cornerRadius = 10.0
    @Pref("siteTint") var siteTint = true
    @Pref("compactTabs") var compactTabs = false
    @Pref("showFullURL") var showFullURL = false
    @Pref("statusBar") var statusBar = true
    /// The icon in the Dock and in Finder, by AppIcon id.
    @Pref("appIcon") var appIcon = AppIcon.defaultID

    // Start page
    @Pref("startBackground") var startBackground = StartBackground.aurora
    @Pref("startImage") var startImagePath = ""
    @Pref("startVideo") var startVideoPath = ""
    @Pref("animateBackground") var animateBackground = false
    @Pref("showClock") var showClock = true
    @Pref("showGreeting") var showGreeting = true
    @Pref("userName") var userName = ""
    @Pref("showFavorites") var showFavorites = true

    // Tabs
    @Pref("hibernate") var hibernateMinutes = 15
    @Pref("newTabPosition") var newTabPosition = NewTabPosition.afterCurrent
    @Pref("restoreSession") var restoreSession = true
    @Pref("blockAutoplay") var blockAutoplay = true
    @Pref("checkUpdates") var checkUpdates = true
    @Pref("paletteOnNewTab") var paletteOnNewTab = true
    @Pref("organizeTabs") var organizeTabs = false
    /// A card with the page, its site and its memory when the pointer rests on a tab.
    @Pref("tabPreviews") var tabPreviews = true
    /// Pinned tabs keep their site: links to other sites open in new tabs, as in Arc.
    @Pref("pinnedStayOnSite") var pinnedStayOnSite = true
    /// How many tabs from one site make a group: 2, 3 or 5.
    @Pref("groupThreshold") var groupThreshold = 3
    /// Sites never grouped by site, as registrable domains ("github.com").
    @Pref("groupExceptions") var groupExceptions: [String] = []
    @Pref("popupMode") var popupMode = PopupMode.automatic
    @Pref("autoCloseDays") var autoCloseDays = 0
    @Pref("alwaysShowTitles") var alwaysShowTitles = false
    @Pref("pullToRefresh") var pullToRefresh = true
    @Pref("profiles") var profiles: [Profile] = []
    /// Keep long text typed into pages until it's sent, to put it back after a reload: see Drafts.
    @Pref("recoverDrafts") var recoverDrafts = true
    /// Saved lists of steps: see Automation.
    @Pref("automations") var automations: [Automation] = []
    /// Where links to particular sites open: see OpeningRules.
    @Pref("openingRules") var openingRules: [OpeningRule] = []
    /// With profiles set up, the first window asks which one to use, as Chrome does.
    @Pref("askProfile") var askProfileAtLaunch = true
    @Pref("onboarded") var onboarded = false

    // Search
    @Pref("engine") var engine = SearchEngine.duckduckgo
    @Pref("customSearch") var customSearch = "https://duckduckgo.com/?q=%s"
    @Pref("suggestions") var suggestions = false
    /// Completing addresses of often-visited sites as you type in the command bar.
    @Pref("inlineCompletion") var inlineCompletion = true
    /// Sites allowed to open pop-up windows without a click, by site name.
    @Pref("popupSites") var popupSites: [String] = []
    @Pref("shortcuts") var shortcuts: [SearchShortcut] = [
        SearchShortcut(keyword: "yt", name: "YouTube", template: "https://www.youtube.com/results?search_query=%s"),
        SearchShortcut(keyword: "w", name: "Wikipedia", template: "https://en.wikipedia.org/wiki/Special:Search?search=%s"),
        SearchShortcut(keyword: "gh", name: "GitHub", template: "https://github.com/search?q=%s"),
        SearchShortcut(keyword: "maps", name: "Maps", template: "https://maps.apple.com/?q=%s"),
        SearchShortcut(keyword: "r", name: "Reddit", template: "https://www.reddit.com/search/?q=%s"),
    ]

    // Shield
    @Pref("adBlock") var adBlock = true
    @Pref("easyList") var easyList = false
    @Pref("easyPrivacy") var easyPrivacy = false
    @Pref("adGuardBase") var adGuardBase = false
    @Pref("fanboyAnnoyance") var fanboyAnnoyance = false
    @Pref("cnameTrackers") var cnameTrackers = false
    @Pref("youtubeAds") var youtubeAds = true
    @Pref("cookieBanners") var hideCookieBanners = true
    /// Answers the banner with "Reject all" where the site offers it, so it doesn't come back and nothing optional is allowed.
    @Pref("rejectCookies") var rejectCookies = true
    /// Makes canvas, WebGL and audio readings differ a little per site, so they can't be used to recognise this Mac.
    @Pref("fingerprinting") var fingerprintProtection = true
    @Pref("thirdPartyCookies") var blockThirdPartyCookies = true
    @Pref("stripTracking") var stripTracking = true
    @Pref("httpsUpgrade") var httpsUpgrade = true
    @Pref("gpc") var gpc = true
    @Pref("clearOnQuit") var clearOnQuit = false
    @Pref("allowlist") var allowlist: [String] = []

    // Passwords and security
    @Pref("savePasswords") var savePasswords = true
    @Pref("autofillPasswords") var autofillPasswords = true
    @Pref("strongPasswords") var suggestStrongPasswords = false
    @Pref("passwordManager") var passwordManager = ""
    @Pref("neverSave") var neverSaveHosts: [String] = []

    // Searching what pages said
    /// Keep the text of visited pages on this Mac, to find them by what they said.
    @Pref("rememberPageText") var rememberPageText = true
    /// How long that text is kept, in days.
    @Pref("pageTextDays") var pageTextDays = 90
    /// Sites whose pages' text is never kept.
    @Pref("pageTextExcluded") var pageTextExcluded: [String] = []
    @Pref("httpsOnly") var httpsOnly = false
    @Pref("confirmDownloads") var confirmDangerousDownloads = true
    @Pref("lockPrivate") var lockPrivateWindows = true

    // Sites
    @Pref("siteStyles") var siteStyles: [SiteStyle] = []

    /// The style for a site, if it has one.
    func siteStyle(for host: String?) -> SiteStyle? {
        siteStyles.filter { $0.matches(host) }.max { $0.host.count < $1.host.count }
    }

    /// Saves a style, replacing the one with the same id; an empty style is removed.
    func saveSiteStyle(_ style: SiteStyle) {
        var list = siteStyles.filter { $0.id != style.id }
        if !style.isEmpty { list.append(style) }
        siteStyles = list.sorted { $0.host < $1.host }
    }
    @Pref("siteZoom") var siteZoom: [String: Double] = [:]
    @Pref("defaultZoom") var defaultZoom = 1.0
    /// Camera and microphone choices per site, keyed by `MediaPermission.key`.
    @Pref("mediaPermissions") var mediaPermissions: [String: Bool] = [:]
    @Pref("forceDark") var forceDark = false

    // AI assistant
    @Pref("aiEnabled") var aiEnabled = false
    /// Whether the user has been told about the assistant, in the setup or after updating to 1.5.4.
    @Pref("aiIntroduced") var aiIntroduced = false
    /// The version whose "Welcome to Tacet" screen was shown, or that was set up fresh.
    @Pref("welcomedVersion") var welcomedVersion = ""
    @Pref("aiProvider") var aiProvider = AIProvider.anthropic
    /// The model chosen for each provider, keyed by `AIProvider.rawValue`.
    @Pref("aiModels") var aiModels: [String: String] = [:]
    @Pref("aiBaseURL") var aiBaseURL = AIProvider.custom.defaultBaseURL
    /// Addresses of Ollama and LM Studio when they aren't at their usual place, by provider.
    @Pref("aiLocalURLs") var aiLocalURLs: [String: String] = [:]
    /// Image support the user set by hand, keyed by `AIProvider.visionKey`; other models are detected.
    @Pref("aiVision") var aiVision: [String: Bool] = [:]
    /// Lets the assistant search the web and read pages by itself.
    @Pref("aiWeb") var aiWeb = true
    /// How far a deep research goes.
    @Pref("aiResearchDepth") var aiResearchDepth: ResearchDepth = .standard
    /// The order web searches try the engines in, by `SearchEngineKind.rawValue`. Engines that aren't set up are
    /// skipped, so with nothing set up searches go to DuckDuckGo.
    @Pref("aiSearchOrder") var aiSearchOrder = SearchEngineKind.defaultOrder
    /// The address of a SearXNG server the user chose, perhaps their own; empty, SearXNG isn't used.
    @Pref("aiSearXNGURL") var aiSearXNGURL = ""
    /// The assistant panel's width, set by dragging its edge.
    @Pref("assistantWidth") var assistantWidth = 380.0
    /// Lets the assistant click, type, scroll and drag on the current page. Off by default.
    @Pref("aiControl") var aiControl = false
    /// Whether the user has read what page control means, before turning it on for the first time.
    @Pref("aiControlExplained") var aiControlExplained = false

    var aiModelName: String {
        let m = (aiModels[aiProvider.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? aiProvider.defaultModel : m
    }
    /// Answers in the command bar use the provider's faster model.
    @Pref("aiQuickFast") var aiQuickFast = true
    /// Tacet Assistant's own character; off, it answers in a neutral voice.
    @Pref("aiPersonality") var aiPersonality = true
    /// Longer, more detailed answers instead of short ones.
    @Pref("aiDetailed") var aiDetailed = false
    /// What the user wants Tacet Assistant to know about them, in their own words; sent with every question.
    @Pref("aiAboutMe") var aiAboutMe = ""
    /// How the user wants it to answer, in their own words.
    @Pref("aiAnswerStyle") var aiAnswerStyle = ""
    /// Whether the two personal instructions also go with questions asked in private windows. Off by default, so a
    /// private window says nothing about who's browsing.
    @Pref("aiInstructionsInPrivate") var aiInstructionsInPrivate = false
    /// Lets the assistant remember short facts between chats, each one only after the user agrees. Off by default.
    @Pref("aiMemory") var aiMemory = false

    var aiQuickModelName: String {
        aiQuickFast ? (aiProvider.fastModel ?? aiModelName) : aiModelName
    }

    /// A model for small jobs behind the scenes, such as titles and notes, for each provider. None chosen means the
    /// default model does them, so nothing changes for people who never set it.
    @Pref("aiSmallModels") var aiSmallModels: [String: String] = [:]

    /// The model small jobs use: the one chosen for them, else the default model.
    var aiSmallModelName: String { Self.smallModel(chosen: aiSmallModels[aiProvider.rawValue], main: aiModelName) }

    /// Whether the user picked a model for small jobs. Extra requests that only make things nicer, such as naming a
    /// chat, are made only then, so nobody pays for them without asking.
    var aiHasSmallModel: Bool { !(aiSmallModels[aiProvider.rawValue] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    static func smallModel(chosen: String?, main: String) -> String {
        let m = (chosen ?? "").trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? main : m
    }

    // Advanced
    @Pref("developer") var developer = false
    @Pref("javaScript") var javaScript = true
    @Pref("uaMode") var uaMode = UserAgentMode.safari
    @Pref("customUA") var customUA = ""
    @Pref("askDownload") var askDownloadLocation = false
    /// Days a finished download stays in the list; 0 keeps it until it's cleared by hand.
    @Pref("downloadsKeepDays") var downloadsKeepDays = 7

    var accent: Color { Color(hex: accentHex) }

    var accentBinding: Binding<Color> {
        Binding(get: { Color(hex: self.accentHex) },
                set: { self.accentHex = $0.hexString })
    }

    func isAllowlisted(_ host: String?) -> Bool {
        ShieldExceptions.covers(allowlist, host)
    }

    /// Shield is off on `host`: kept off in the allowlist, or for now from "Site not working?".
    func isShieldOff(_ host: String?) -> Bool {
        isAllowlisted(host) || ShieldTrial.shared.isOff(host)
    }

    /// The Shield switches for a site. Either way a "for now" exception gives way to your choice.
    func setShield(_ host: String, on: Bool) {
        if on {
            ShieldTrial.shared.turnBackOn(host)
            setAllowlisted(host, false)
        } else {
            setAllowlisted(host, true)
            ShieldTrial.shared.keepOff(host)
        }
    }

    func isGroupException(_ host: String?) -> Bool {
        guard let host else { return false }
        return groupExceptions.contains(PasswordStore.site(host))
    }

    func setGroupException(_ host: String, _ excepted: Bool) {
        let site = PasswordStore.site(host)
        var list = groupExceptions.filter { $0 != site }
        if excepted { list.append(site) }
        groupExceptions = list.sorted()
    }

    func setAllowlisted(_ host: String, _ allowed: Bool) {
        let h = ShieldExceptions.site(host)
        var list = allowlist.filter { $0 != h }
        if allowed { list.append(h) }
        allowlist = list.sorted()
    }

    func didChange(_ key: String) {
        if key == "theme" { applyTheme() }
        if key == "appIcon" { AppIcon.applyChosen(force: true) }
        if key == "rememberPageText" && !rememberPageText { PageText.shared.clear() }
        if key == "pageTextDays" { PageText.shared.prune(keepingDays: pageTextDays) }
        if key == "recoverDrafts" && !recoverDrafts { Drafts.shared.clear() }
        if key == "profiles" { ProfileProxies.refresh() }
        NotificationCenter.default.post(name: .settingChanged, object: self, userInfo: ["key": key])
    }

    func applyTheme() {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Language

/// Looks up a translation for text that isn't a SwiftUI string literal.
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, it, fr
    var id: String { rawValue }

    /// Each language is named in itself, so it can be found in any locale.
    var label: String {
        switch self {
        case .system: L("System")
        case .en: "English"
        case .it: "Italiano"
        case .fr: "Français"
        }
    }

    static var current: AppLanguage {
        guard let list = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = list.first else { return .system }
        return AppLanguage(rawValue: String(first.prefix(2))) ?? .system
    }

    /// Takes effect the next time Tacet starts.
    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    static func relaunch() {
        Session.shared.saveNow()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - User agent

enum UserAgent {
    /// The installed Safari's version, so sites treat Tacet like current Safari.
    static let safariVersion: String = {
        let url = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: url),
              let v = dict["CFBundleShortVersionString"] as? String else { return "18.0" }
        return v.split(separator: ".").prefix(2).joined(separator: ".")
    }()

    static let applicationName = "Version/\(safariVersion) Safari/605.1.15"

    static var custom: String? {
        let s = Settings.shared
        return s.uaMode == .custom && !s.customUA.isEmpty ? s.customUA : nil
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0x5E5CE6
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#5E5CE6" }
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}

extension NSColor {
    /// Relative luminance in 0...1.
    var luminance: Double {
        guard let c = usingColorSpace(.sRGB) else { return 1 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}
