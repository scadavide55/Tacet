import SwiftUI

/// "Welcome to Tacet <version>": the new features of an update, one page each with a small looping example.
/// Shown once, the first time a new version opens, to people who used an earlier one.
/// Every release adds its own pages; people coming from an older version also see the pages of the versions they skipped.
enum WhatsNew {
    struct Page: Identifiable {
        let id = UUID()
        /// The version that brought it.
        var version = "1.6.1"
        let symbol: String
        let title: LocalizedStringKey
        let text: LocalizedStringKey
        let how: [LocalizedStringKey]
        let demo: Demo
    }

    enum Demo { case research, activity, developer, downloads, quickAnswer, icons, store, cutout, extMenu, localAI, pinned, arc, shield, preview, wake, translate, passwords, keychain, rename, groups, picking, assistant, apple, reading, customize, extensions, fixes }

    /// What's new for someone who last saw the welcome of `seen` (empty when they never did).
    static func pages(since seen: String) -> [Page] {
        all.filter { seen.isEmpty || UpdateChecker.isNewer($0.version, than: seen) }
    }

    static let all: [Page] = [
        Page(version: "1.8", symbol: "binoculars", title: "Deep research",
             text: "Turn on Deep research and Tacet plans the question, searches from several angles at once, reads the best pages, keeps notes only with the exact words that back them, counts a fact as confirmed when two sites agree, and writes a report with its sources linked and what's still uncertain. Choose Quick, Standard or Thorough, stop at any time, export it as Markdown or PDF.",
             how: ["Deep research, below the chat box, and its menu for how far it goes", "Export Report, below a finished research"],
             demo: .research),
        Page(version: "1.8", symbol: "checkmark.circle", title: "Answers you can check",
             text: "A link to a page the assistant never read is dimmed and marked. It reads PDFs page by page and pages built with JavaScript. Searches can use SearXNG or Brave Search, and move on when one engine fails. Models on your Mac get the context they need, so the instructions are never cut off.",
             how: ["Settings › AI › Web access, for search engines", "Settings › AI, for a local model's context"],
             demo: .localAI),
        Page(version: "1.8", symbol: "person.text.rectangle", title: "An assistant that knows you",
             text: "Tell it about yourself and how to answer. Turn on memory and it offers to remember a fact, saved only when you click Save. Type @ to send open tabs with a question, search every saved chat by what was said, pin chats and export them, and see the tokens each answer used.",
             how: ["Settings › AI › Personal instructions and Memory", "Type @ in the message box"],
             demo: .assistant),
        Page(version: "1.8", symbol: "list.bullet.rectangle", title: "See what the assistant is doing",
             text: "One tidy line says what's happening now, Searching the web, Reading 3 pages, Thinking, with the time on the right. Click it to see every search and page, how each went and how long it took; a click on a page opens it.",
             how: ["Click the line above a reply to open or close the steps"],
             demo: .activity),
        Page(version: "1.8", symbol: "sparkles", title: "Better answers",
             text: "Tacet Assistant is no longer a beta (Deep research and Browser use still are). Replies are laid out with headings, lists, tables and code you can copy, sources sit below as small chips, and Ask Again tries once more. Searches and pages are read at the same time, and a busy service is retried by itself.",
             how: ["The buttons below a reply: Copy and Ask Again"],
             demo: .assistant),
        Page(version: "1.8", symbol: "command", title: "A smarter command bar and Find",
             text: "Type the start of a site you visit often and the command bar completes it; Tab or → accepts. It converts units (10 km, 21 °C to F) and switches to a tab that already has the address. Find on Page counts and highlights every match, narrows as you type, and ⌘E finds the selected text.",
             how: ["⌘K, then type gi… and press Tab", "⌘F, then the options button for Match Case and Whole Words"],
             demo: .quickAnswer),
        Page(version: "1.8", symbol: "exclamationmark.bubble", title: "Pages can't take over",
             text: "A page's alerts wait their turn on its own window instead of stopping Tacet, and from the second one you can silence them. A red mark shows a tab using the camera or microphone, which never goes to sleep; a click pauses them. Sound in embedded players shows on the tab and mutes with it, and a blocked pop-up says so.",
             how: ["Click the red camera or microphone mark on a tab to pause"],
             demo: .fixes),
        Page(version: "1.8", symbol: "lock.shield", title: "Privacy and sign-ins",
             text: "Anti-fingerprinting can no longer be spotted by the sites it protects you from. Saved passwords fill sign-in boxes embedded in pages, on the same site only, and a site's own sign-in window uses your saved login. If Tacet ever quits unexpectedly, it asks before reopening your windows.",
             how: ["Nothing to set: it's all on"],
             demo: .keychain),
        Page(version: "1.8", symbol: "clock.arrow.circlepath", title: "Your whole history, best first",
             text: "Searching history now looks through every page you ever visited, at once and without slowing your typing. The pages you open often and recently come first, those you typed come before links, and the site you start typing comes before pages that only mention it.",
             how: ["Type in the command bar (⌘K) or in History (⌘Y)"],
             demo: .reading),
        Page(version: "1.8", symbol: "camera.viewfinder", title: "Screenshots and site information",
             text: "Take a screenshot of the whole page, however long, or of just the part you click. The lock now shows everything about the site in one place: its certificate, camera and microphone, zoom, pop-ups and Tacet Shield, with Clear Data for This Site.",
             how: ["File › Take Screenshot of Whole Page (⌥⇧⌘S) or of Element…", "Click the lock next to the address"],
             demo: .customize),
        Page(version: "1.8", symbol: "shield.lefthalf.filled", title: "When a site doesn't work",
             text: "Site not working? in Tacet Shield turns it off on that site for now and reloads the page, then asks whether to keep it off. Nothing is sent anywhere. A profile can go through its own proxy, and its windows say so; private windows never do.",
             how: ["The shield button › Site not working?", "Settings › General › Profiles, the network button of a profile"],
             demo: .shield),
        Page(version: "1.8", symbol: "keyboard", title: "Small things that add up",
             text: "Close several tabs and Undo brings them back. The space bar shows a download in Quick Look. Settings has a search field, the tab list works with the arrow keys, file fields offer only the files they take, and Help › Copy Diagnostic Log shows you what it would copy.",
             how: ["⌥⌘↓ moves to the tab list: ↑ ↓, Return opens, ⌘⌫ closes", "The search field at the top of Settings (⌘,)"],
             demo: .fixes),
        Page(version: "1.7.1", symbol: "hammer", title: "Developer Mode",
             text: "The Web Inspector and JavaScript console, Inspect Element, the page's source, Responsive Design Mode for phones and tablets, other browsers' user agents, page load times, and switches for JavaScript, styles and caches.",
             how: ["Settings › Advanced › Developer Mode, then the Develop menu", "⌥⌘I Web Inspector · ⌥⌘U page source · ⌥⌘C console"],
             demo: .developer),
        Page(version: "1.7.1", symbol: "arrow.down.circle", title: "Better downloads",
             text: "Each download shows its speed and how long is left. Pause and resume it, download it again, and find past downloads in the Library, even after Tacet restarts. A tab opened only for a file closes by itself.",
             how: ["The downloads button, or Library › Downloads (⌥⌘L)", "Right-click a download for every option"],
             demo: .downloads),
        Page(version: "1.7.1", symbol: "sparkles", title: "A quicker, sharper assistant",
             text: "Tacet Assistant now gets to the point, with a calm voice of its own. Questions from the command bar start answering much sooner: a short prompt, a warm connection, and a faster model where your provider has one. And a sum typed there is worked out at once, with no AI at all.",
             how: ["Type a question in the command bar (⌘K), then ↓ and Return", "Settings › AI › Answers: length, personality, faster answers"],
             demo: .quickAnswer),
        Page(version: "1.7.1", symbol: "speedometer", title: "Faster and steadier",
             text: "Links to other sites start connecting as you point at them. Switching tabs does less work, memory is given back when the Mac runs short, a window closed by mistake comes back with ⇧⌘T, and many small fixes make Tacet more reliable.",
             how: ["Nothing to set: it's all on"], demo: .fixes),
        Page(version: "1.7", symbol: "square.stack", title: "Spaces",
             text: "A Space keeps a whole set of tabs, groups and pinned tabs with a note to yourself. Leave School, open Coding, and come back to School exactly as it was.",
             how: ["The icons at the bottom of the sidebar, or the Space button at the top", "⌃⌘← and ⌃⌘→ go to the previous and next Space"],
             demo: .groups),
        Page(version: "1.7", symbol: "doc.text.magnifyingglass", title: "Find pages by what they said",
             text: "Tacet keeps the text of the pages you read on this Mac, so a sentence you remember finds the page again, with the passage. No AI, nothing leaves your Mac.",
             how: ["Search History, or type in the command bar", "Settings › Shield › Searching what pages said"],
             demo: .reading),
        Page(version: "1.7", symbol: "highlighter", title: "Preview, highlight, take notes",
             text: "⌥-click a link to read it over the page without leaving it. Select text to highlight it in a colour with a note; Library › Highlights keeps them all, ready for Obsidian.",
             how: ["⌥-click a link; Esc closes the preview", "Right-click selected text › Highlight"],
             demo: .customize),
        Page(version: "1.7", symbol: "bolt", title: "Rules, drafts and automations",
             text: "Send a site's links to a profile, a Space or a private window. Get back text you hadn't sent when a page reloads. Run your own steps with a shortcut.",
             how: ["Settings › General › Opening rules", "Settings › Automations, then ⌃⌥⌘1 to ⌃⌥⌘9"],
             demo: .extMenu),
        Page(version: "1.7", symbol: "checkmark.shield", title: "Passkeys and a safer Tacet",
             text: "When a site asks for a passkey, Tacet signs you in through Safari with Touch ID. Tacet Assistant asks before buttons it can't judge, and a broken certificate is never opened over HTTP behind your back.",
             how: ["Sign In with Safari, then I'm Signed In"],
             demo: .keychain),
        Page(version: "1.6.5", symbol: "app.badge", title: "A new icon",
             text: "Seal, corona is Tacet's new icon. Prefer another? Pick one of sixteen alternatives, including Eclipse, the icon Tacet had until now. The Dock and Finder show it at once.",
             how: ["Settings › Appearance › App icon"],
             demo: .icons),
        Page(version: "1.6.5", symbol: "checkmark.seal", title: "Fixes from your reports",
             text: "In the compact layout the whole top bar moves the window. Sign-in fields built from web components, like Reddit's, now fill. A Safari import that waited for Full Disk Access finishes by itself once you turn it on.",
             how: ["Thanks to everyone who opened an issue on GitHub"], demo: .fixes),
        Page(version: "1.6.4", symbol: "storefront", title: "Tacet Plugins",
             text: "A store of small plugins made for Tacet and checked by us, that work on every Mac: YouTube without Shorts, Copy as Markdown, Smart Dark Mode, Focus Timer and many more. Each says who made it and whether it's verified.",
             how: ["Window › Tacet Plugins (⇧⌘P), or the store button in the sidebar", "Add installs it; plugins update by themselves"],
             demo: .store),
        Page(version: "1.6.4", symbol: "scissors", title: "Cutout: remove backgrounds",
             text: "Remove the background of any picture, on this Mac, with no upload. Its AI engines download once when you add it, then it works offline.",
             how: ["Rest the pointer on a picture and click ✂ Cutout, or press ⌥⇧X", "Or right-click a picture › Remove Background with Cutout"],
             demo: .cutout),
        Page(version: "1.6.4", symbol: "puzzlepiece.extension", title: "Every extension in one place",
             text: "The puzzle button lists your plugins and extensions. A click opens, runs, turns on or off, or explains each one, so there are no shortcuts to remember.",
             how: ["Pin one to the toolbar with its pin", "Right-click a plugin to turn it off for one site"],
             demo: .extMenu),
        Page(version: "1.6.4", symbol: "sparkles", title: "A smarter Tacet Assistant",
             text: "It knows everything about Tacet, from where a setting is to every shortcut, and it uses your plugins when you ask. Ollama and LM Studio now run it on your Mac with no key.",
             how: ["“How do I open Tacet Plugins?”", "“Remove the background of this picture”", "Settings › AI › Ollama or LM Studio"],
             demo: .localAI),
        Page(version: "1.6.4", symbol: "pin", title: "Tabs that behave",
             text: "Pinned tabs keep their site, as in Arc: links to other sites open in a new tab. ⇧⌘T brings back every tab you closed together, and a middle-click closes a tab.",
             how: ["Right-click a pinned tab › Back to Pinned Address", "With profiles, Tacet asks who's browsing when it opens"],
             demo: .pinned),
        Page(version: "1.6.4", symbol: "checkmark.seal", title: "And more",
             text: "Move your settings and plugins to another Mac in one file. Windows snap to the screen's edges, full screen has no empty gap, and the password check is always in Settings.",
             how: ["Settings › General › Move to another Mac"], demo: .fixes),
        Page(version: "1.6.3", symbol: "square.and.arrow.down.on.square", title: "Bring your Arc sidebar",
             text: "Arc stops working on December 22. Tacet reads your Spaces, Favorites, pinned tabs and folders straight from Arc: Favorites become pinned tabs, and each Space and folder a tab group that loads only when you open it.",
             how: ["File › Import from Another Browser…, then choose Arc", "Keep “Spaces and pinned tabs” on"],
             demo: .arc),
        Page(version: "1.6.3", symbol: "shield.lefthalf.filled", title: "A stronger Tacet Shield",
             text: "The shield now shows what it blocked on the page, on the site and since you opened Tacet. It also rejects optional cookies for you, protects against fingerprinting, and can use more filter lists.",
             how: ["Click the shield in the toolbar to see the numbers and the sites", "Settings › Shield: AdGuard, Fanboy Annoyances and hidden trackers"],
             demo: .shield),
        Page(version: "1.6.3", symbol: "rectangle.on.rectangle", title: "Tab previews",
             text: "Rest the pointer on a tab to see the page, its site and how much memory it uses. Tabs that are sleeping say so, and use none.",
             how: ["Turn it off in Settings › General › Tabs", "⌥⌘F searches your tabs by title or address"],
             demo: .preview),
        Page(version: "1.6.3", symbol: "moon.zzz", title: "Tabs wake up as you left them",
             text: "A sleeping tab shows the page as you last saw it while it loads again, then puts you back where you had scrolled to. No white flash, no jump to the top.",
             how: [], demo: .wake),
        Page(version: "1.6.3", symbol: "translate", title: "Translate, listen, focus",
             text: "Translate a page on this Mac with Apple's translation: nothing leaves your Mac. Have an article read aloud, or hide everything but the page with Focus Mode.",
             how: ["View › Translate Page (⌥⌘T)", "View › Read Aloud (⌥⌘A)", "View › Focus Mode (⇧⌘J)"],
             demo: .translate),
        Page(version: "1.6.3", symbol: "key.fill", title: "Password check",
             text: "Find saved passwords that appeared in data breaches, that you use on more than one site, or that are easy to guess. Only the first 5 characters of a password's hash are ever sent to check it.",
             how: ["Settings › Passwords › Check…"], demo: .passwords),
        Page(version: "1.6.3", symbol: "checkmark.seal", title: "One last Keychain question",
             text: "Tacet now has a signature of its own, so after this update macOS may ask once more to let Tacet use its Keychain items. Choose Always Allow: future updates won't ask again.",
             how: ["Apps installed from sites move to ~/Applications/Tacet Apps and update with Tacet",
                   "Turning off an extension closes its pages too"],
             demo: .keychain),
        Page(version: "1.6.2", symbol: "moon.circle", title: "Lumen is now Tacet",
             text: "Same browser, new name. There were already other browsers called Lumen, and the name sounded too much like an AI product. Tacet is the mark in music for silence, where an instrument stays quiet: like the ads and trackers Tacet keeps out.",
             how: ["Your tabs, passwords, settings and extensions are all still here",
                   "The new icon is an eclipse: a dark disc in front of the sun"],
             demo: .rename),
        Page(version: "1.6.2", symbol: "wrench.and.screwdriver", title: "Small fixes",
             text: "The setup fits its window again, removing an extension also deletes what it stored, and tabs sent to a new window come back if the window doesn't open.",
             how: [], demo: .fixes),
        Page(symbol: "square.grid.3x1.folder.badge.plus", title: "Tabs that tidy themselves",
             text: "Tabs from the same site gather into a group once there are 2, 3 or 5 of them, as you choose. Groups can be saved, closed and opened again later, whole.",
             how: ["Settings › General › Tabs: when to group, and sites never to group",
                   "Right-click a group: New Tab in Group, Save and Close Group, Move Group to Window",
                   "Close duplicate tabs and sort tabs from the Tab menu or the command bar"],
             demo: .groups),
        Page(symbol: "cursorarrow.click.2", title: "Pick several tabs at once",
             text: "⌘-click or ⇧-click tabs to pick them, then group, move, pin or close them together. Drag them all at once too.",
             how: ["⌘-click adds a tab, ⇧-click picks a range", "Right-click a picked tab for everything you can do with them"],
             demo: .picking),
        Page(symbol: "sparkles", title: "Tacet Assistant does more",
             text: "It reads your other tabs, finds pages in your history and bookmarks, summarises YouTube videos from their transcript, takes screenshots, and groups tabs by topic.",
             how: ["“Compare the products in my tabs”", "“Find that SwiftUI article I read yesterday”",
                   "“Summarise this video”", "Select text and right-click › Tacet Assistant"],
             demo: .assistant),
        Page(symbol: "apple.logo", title: "Apple's model, on your Mac",
             text: "Choose Apple (on this Mac) in Settings › AI to use the assistant for free, offline, with nothing leaving your Mac. It's smaller than cloud models, so it's best for short, simple questions.",
             how: ["Needs Apple Intelligence turned on", "Use a cloud provider for long pages and hard questions"],
             demo: .apple),
        Page(symbol: "eyeglasses", title: "Read later, even offline",
             text: "In Reader, choose Save for Offline: the article and its images are kept on your Mac, ready without a connection.",
             how: ["Open Reader with ⇧⌘R, then Save for Offline at the bottom right", "Find your articles in the Library › Reading List"],
             demo: .reading),
        Page(symbol: "paintbrush", title: "Make any site yours",
             text: "Customize This Site changes a site's colours, font and width, hides pop-ups and floating bars, and hides anything you click. Changes show as you make them.",
             how: ["⋯ menu › Customize This Site…", "Pick Elements to Hide, then ↑ for a bigger block and Esc when done",
                   "Add your own CSS and JavaScript under Advanced"],
             demo: .customize),
        Page(symbol: "puzzlepiece.extension", title: "Extensions",
             text: "Add the Safari extensions that come with your apps in one click, or Chrome, Firefox and other WebExtensions from a file. They never run in private windows.",
             how: ["Settings › Extensions", "Their buttons appear next to the shield"],
             demo: .extensions),
        Page(symbol: "checkmark.seal", title: "Steadier than ever",
             text: "Every window comes back when Tacet opens, closed windows stay closed, and links from other apps open as tabs instead of empty windows.",
             how: [], demo: .fixes),
    ]
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    /// Kept from when the sheet opened: once it's dismissed the version counts as seen, and a sheet drawn again while
    /// it closes would otherwise find no pages.
    @State private var pages = WhatsNew.pages(since: Settings.shared.welcomedVersion)

    var body: some View {
        if pages.isEmpty {
            Color.clear.frame(width: 1, height: 1)
        } else {
            pageView(pages[min(index, pages.count - 1)])
        }
    }

    private func pageView(_ page: WhatsNew.Page) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(String(format: L("Welcome to Tacet %@"), UpdateChecker.currentVersion))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Text(page.title).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center)
            }
            .padding(.top, 26)

            DemoView(demo: page.demo)
                .id(page.id)
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.05)))
                .padding(.horizontal, 30).padding(.vertical, 18)
                .transition(.opacity)

            VStack(alignment: .leading, spacing: 10) {
                Text(page.text).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(page.how.enumerated()), id: \.offset) { _, line in
                    Label { Text(line).font(.callout) } icon: { Image(systemName: "arrow.right.circle.fill").foregroundStyle(.tint) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 34)

            Spacer(minLength: 12)

            HStack {
                Button("Skip") { dismiss() }.buttonStyle(.link)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle().fill(i == index ? Color.accentColor : Color.primary.opacity(0.2)).frame(width: 7, height: 7)
                            .onTapGesture { withAnimation { index = i } }
                    }
                }
                Spacer()
                if index > 0 { Button("Back") { withAnimation { index -= 1 } } }
                Button(index == pages.count - 1 ? LocalizedStringKey("Start Browsing") : "Next") {
                    if index == pages.count - 1 { dismiss() } else { withAnimation { index += 1 } }
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 600, height: 600)
    }
}

/// A small looping example of a feature, drawn with plain shapes so it looks the same in every language.
private struct DemoView: View {
    let demo: WhatsNew.Demo

    var body: some View {
        TimelineView(.animation) { context in
            // A 4-second loop, eased so each step settles before the next.
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4
            switch demo {
            case .research: ResearchDemo(t: t)
            case .activity: ActivityDemo(t: t)
            case .developer: DeveloperDemo(t: t)
            case .downloads: DownloadsDemo(t: t)
            case .quickAnswer: QuickAnswerDemo(t: t)
            case .icons: IconsDemo(t: t)
            case .store: StoreDemo(t: t)
            case .cutout: CutoutDemo(t: t)
            case .extMenu: ExtMenuDemo(t: t)
            case .localAI: LocalAIDemo(t: t)
            case .pinned: PinnedDemo(t: t)
            case .arc: ArcDemo(t: t)
            case .shield: ShieldDemo(t: t)
            case .preview: PreviewDemo(t: t)
            case .wake: WakeDemo(t: t)
            case .translate: TranslateDemo(t: t)
            case .passwords: PasswordsDemo(t: t)
            case .keychain: KeychainDemo(t: t)
            case .rename: RenameDemo(t: t)
            case .groups: GroupsDemo(t: t)
            case .picking: PickingDemo(t: t)
            case .assistant: AssistantDemo(t: t)
            case .apple: AppleDemo(t: t)
            case .reading: ReadingDemo(t: t)
            case .customize: CustomizeDemo(t: t)
            case .extensions: ExtensionsDemo(t: t)
            case .fixes: FixesDemo(t: t)
            }
        }
    }
}

/// 0 before `a`, 1 after `b`, eased in between.
private func step(_ t: Double, _ a: Double, _ b: Double) -> Double {
    let x = min(1, max(0, (t - a) / (b - a)))
    return x * x * (3 - 2 * x)
}

private struct Chip: View {
    let color: Color
    var label: String = ""
    var width: CGFloat = 70
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.25)).frame(width: width - 30, height: 5)
        }
        .frame(width: width, height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08)))
    }
}

/// The activity line pulses through the research stages, then the report's lines and source chips appear.
private struct ResearchDemo: View {
    let t: Double
    var body: some View {
        let stage = min(3, Int(t / 0.15))
        let report = step(t, 0.62, 0.8)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                ActivityDots(active: report < 1, tick: Int(t * 16))
                Image(systemName: "binoculars").font(.system(size: 10)).foregroundStyle(.secondary)
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.45)).frame(width: [90, 120, 80, 110][stage], height: 6)
                Text("\(Int(t * 95))s").font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.55)).frame(width: 110, height: 7)
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.28)).frame(width: [240, 210, 170][i], height: 5)
                }
                HStack(spacing: 5) {
                    ForEach(0..<4) { _ in Capsule().fill(Color.primary.opacity(0.12)).frame(width: 46, height: 14) }
                }
                .padding(.top, 3)
            }
            .opacity(report)
        }
        .frame(width: 280, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
    }
}

/// The activity line opens into its steps, one row each, then closes again.
private struct ActivityDemo: View {
    let t: Double
    var body: some View {
        let open = step(t, 0.2, 0.32) * (1 - step(t, 0.85, 0.95))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ActivityDots(active: true, tick: Int(t * 16))
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.45)).frame(width: 130, height: 6)
                Text("\(Int(t * 24))s").font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(90 * open))
                Spacer()
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<4) { i in
                    HStack(spacing: 8) {
                        Image(systemName: ["magnifyingglass", "doc.text", "doc.text", "ellipsis.bubble"][i]).font(.system(size: 10)).foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.3)).frame(width: [150, 120, 135, 90][i], height: 5)
                        Spacer()
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.15)).frame(width: 16, height: 5)
                    }
                    .padding(.horizontal, 10).frame(height: 24)
                    .opacity(step(t, 0.3 + Double(i) * 0.08, 0.38 + Double(i) * 0.08))
                    if i < 3 { Divider() }
                }
            }
            .frame(height: 100 * open, alignment: .top)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)).opacity(open))
        }
        .frame(width: 280, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
    }
}

/// An element on a page gets outlined, then the inspector slides up below the page.
private struct DeveloperDemo: View {
    let t: Double
    var body: some View {
        let pick = step(t, 0.15, 0.3)
        let open = step(t, 0.4, 0.6)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.4)).frame(width: 120, height: 8)
                RoundedRectangle(cornerRadius: 4).fill(Color.teal.opacity(0.45)).frame(width: 200, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2).opacity(pick))
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.2)).frame(width: 180, height: 5)
            }
            .padding(12)
            .frame(width: 260, alignment: .leading)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<4) { i in
                        RoundedRectangle(cornerRadius: 2).fill((i == 1 ? Color.accentColor : Color.primary).opacity(i == 1 ? 0.6 : 0.25))
                            .frame(width: [90, 120, 80, 100][i], height: 5).padding(.leading, CGFloat(i % 2) * 10)
                    }
                }
                Spacer()
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 14)).foregroundStyle(.tint)
            }
            .padding(10)
            .frame(width: 260, height: 70 * open, alignment: .top)
            .clipped()
            .background(Color.primary.opacity(0.08))
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A download fills with its speed and time left, pauses, then finishes.
private struct DownloadsDemo: View {
    let t: Double
    var body: some View {
        let paused = t > 0.45 && t < 0.6
        let progress = min(1, t < 0.45 ? t / 0.45 * 0.55 : t < 0.6 ? 0.55 : 0.55 + (t - 0.6) / 0.3 * 0.45)
        HStack(spacing: 12) {
            Image(systemName: progress >= 1 ? "doc.fill" : "doc").font(.system(size: 30)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.45)).frame(width: 110, height: 7)
                ProgressView(value: progress).tint(paused ? .secondary : .accentColor).frame(width: 190)
                Text(progress >= 1 ? "48 MB" : paused ? "Paused" : "\(Int(progress * 48)) MB · 12 MB/s · \(max(1, Int((1 - progress) * 4))) s")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
            Image(systemName: progress >= 1 ? "magnifyingglass" : paused ? "play.circle.fill" : "pause.circle.fill")
                .font(.system(size: 18)).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }
}

/// A question in the command bar, and the answer starting almost at once.
private struct QuickAnswerDemo: View {
    let t: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.5)).frame(width: 150 * step(t, 0.0, 0.2), height: 7)
                Spacer()
            }
            .frame(width: 280)
            Divider().frame(width: 280)
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(.tint)
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.3)).frame(width: 70, height: 5)
            }
            .opacity(step(t, 0.25, 0.3))
            ForEach(0..<2) { i in
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.35)).frame(width: [250, 170][i] * step(t, 0.3 + Double(i) * 0.12, 0.42 + Double(i) * 0.12), height: 6)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
    }
}

/// The choice moves along a row of icons, and the big one, as in the Dock, follows it.
private struct IconsDemo: View {
    let t: Double
    private static let ids = ["seal-corona", "seal-night-gold", "half-moon-corona", "corona-gold", "eclipse"]
    var body: some View {
        let chosen = min(Self.ids.count - 1, Int(t * Double(Self.ids.count)))
        HStack(spacing: 26) {
            icon(Self.ids[chosen], 92).id(chosen).transition(.opacity)
            HStack(spacing: 8) {
                ForEach(Array(Self.ids.enumerated()), id: \.offset) { i, id in
                    icon(id, 40)
                        .padding(3)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(i == chosen ? 0.16 : 0)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(i == chosen ? Color.accentColor : .clear, lineWidth: 2))
                }
            }
        }
        .animation(.easeOut(duration: 0.3), value: chosen)
    }

    private func icon(_ id: String, _ size: CGFloat) -> some View {
        Group {
            if let image = AppIconPicker.image(for: AppIcon.find(id)) { Image(nsImage: image).resizable().interpolation(.high) }
            else { RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Color.primary.opacity(0.08)) }
        }
        .frame(width: size, height: size)
    }
}

/// Plugin cards appear one by one, each getting its green check.
private struct StoreDemo: View {
    let t: Double
    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<3) { i in
                let shown = step(t, 0.1 + Double(i) * 0.15, 0.25 + Double(i) * 0.15)
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: ["play.slash", "doc.on.clipboard", "scissors"][i]).font(.system(size: 16)).foregroundStyle(.tint)
                        .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.15)))
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.4)).frame(width: 70, height: 6)
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 9)).foregroundStyle(.green)
                        RoundedRectangle(cornerRadius: 2).fill(Color.green.opacity(0.5)).frame(width: 46, height: 5)
                    }
                    .opacity(step(t, 0.55, 0.7))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                .opacity(shown).offset(y: 12 * (1 - shown))
            }
        }
    }
}

/// A picture's background fades to a checkerboard, leaving the subject.
private struct CutoutDemo: View {
    let t: Double
    var body: some View {
        let cut = step(t, 0.35, 0.6)
        ZStack {
            // Transparency, shown as a checkerboard.
            Canvas { ctx, size in
                let s: CGFloat = 12
                for x in stride(from: 0, to: size.width, by: s) {
                    for y in stride(from: 0, to: size.height, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                        ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.primary.opacity(0.08)))
                    }
                }
            }
            LinearGradient(colors: [.teal, .blue], startPoint: .top, endPoint: .bottom).opacity(1 - cut)
            Image(systemName: "figure.stand").font(.system(size: 92)).foregroundStyle(.orange)
        }
        .frame(width: 200, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            Text(verbatim: "✂ Cutout").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Color.black.opacity(0.8)))
                .padding(8).opacity(1 - step(t, 0.3, 0.4))
        }
    }
}

/// The puzzle menu opens under its button with a few rows.
private struct ExtMenuDemo: View {
    let t: Double
    var body: some View {
        let open = step(t, 0.15, 0.3)
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 16)).foregroundStyle(open > 0.5 ? Color.accentColor : .secondary)
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 16)).foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(0..<3) { i in
                    HStack(spacing: 8) {
                        Image(systemName: ["scissors", "doc.on.clipboard", "bubble.left.and.bubble.right"][i]).font(.system(size: 11)).foregroundStyle(.tint).frame(width: 18)
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.35)).frame(width: 110, height: 6)
                        Circle().fill(i == 2 && step(t, 0.6, 0.65) > 0.5 ? Color.secondary.opacity(0.4) : Color.green).frame(width: 7, height: 7)
                    }
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(i == 2 && t > 0.5 ? 0.15 : 0)))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            .opacity(open).scaleEffect(0.95 + 0.05 * open, anchor: .topTrailing)
        }
    }
}

/// A Mac running the model, with a chat bubble answering.
private struct LocalAIDemo: View {
    let t: Double
    var body: some View {
        HStack(spacing: 26) {
            Image(systemName: "laptopcomputer").font(.system(size: 60, weight: .light))
                .overlay { Image(systemName: "cpu").font(.system(size: 18)).foregroundStyle(.tint).opacity(0.5 + 0.5 * abs(sin(t * .pi * 2))) }
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Color.accentColor.opacity(0.25)).frame(width: 150, height: 20).opacity(step(t, 0.05, 0.15))
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.35)).frame(width: [170, 140, 100][i], height: 6)
                        .opacity(step(t, 0.3 + Double(i) * 0.1, 0.4 + Double(i) * 0.1))
                }
            }
        }
    }
}

/// A pinned tab stays put while the link it opened appears as a new tab.
private struct PinnedDemo: View {
    let t: Double
    var body: some View {
        let open = step(t, 0.35, 0.55)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(.tint)
                    .frame(width: 34, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
                Chip(color: .blue, width: 120)
            }
            Chip(color: .orange, width: 162).opacity(open).offset(x: 20 * (1 - open))
        }
    }
}

/// Arc's sidebar rows slide over and become groups.
private struct ArcDemo: View {
    let t: Double
    var body: some View {
        let move = step(t, 0.25, 0.6)
        HStack(spacing: 46) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<4) { i in Chip(color: [.pink, .pink, .teal, .teal][i], width: 110) }
            }
            .opacity(1 - 0.6 * move).offset(x: 40 * move)
            Image(systemName: "arrow.right").foregroundStyle(.secondary).opacity(1 - move)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<2) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: g == 0 ? "🏠 Home" : "💼 Work").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(g == 0 ? Color.pink : Color.teal)
                        Chip(color: g == 0 ? .pink : .teal, width: 110)
                    }
                    .opacity(step(t, 0.45 + Double(g) * 0.12, 0.6 + Double(g) * 0.12))
                }
            }
        }
    }
}

/// The page counter climbs as requests are stopped.
private struct ShieldDemo: View {
    let t: Double
    var body: some View {
        let n = Int(step(t, 0.1, 0.75) * 23)
        HStack(spacing: 18) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 54)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "\(n)").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                ForEach(0..<3) { i in
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.system(size: 10))
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.25)).frame(width: [90, 70, 110][i], height: 5)
                    }
                    .opacity(step(t, 0.2 + Double(i) * 0.15, 0.3 + Double(i) * 0.15))
                }
            }
        }
    }
}

/// A card opens under a tab the pointer rests on.
private struct PreviewDemo: View {
    let t: Double
    var body: some View {
        let open = step(t, 0.3, 0.45)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) { Chip(color: .blue); Chip(color: .orange); Chip(color: .green) }
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.35)).frame(width: 170, height: 60)
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.4)).frame(width: 120, height: 6)
                HStack(spacing: 4) {
                    Image(systemName: "memorychip").font(.system(size: 9))
                    Text(verbatim: "86 MB").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
            .offset(x: 78)
            .opacity(open).scaleEffect(0.9 + 0.1 * open, anchor: .topLeading)
        }
        .overlay(alignment: .topLeading) {
            Image(systemName: "cursorarrow").font(.system(size: 16)).offset(x: 100, y: 12 - 20 * (1 - step(t, 0.05, 0.25)))
        }
    }
}

/// The picture of the page holds until the page has loaded behind it.
private struct WakeDemo: View {
    let t: Double
    var body: some View {
        let fade = step(t, 0.55, 0.7)
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<5) { i in RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.3)).frame(width: [220, 200, 210, 160, 190][i], height: 6) }
            }
            .opacity(step(t, 0.35, 0.55))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<5) { i in RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.35)).frame(width: [220, 200, 210, 160, 190][i], height: 6) }
            }
            .opacity(1 - fade)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
    }
}

/// Words change language in place; a speaker and the focus frame follow.
private struct TranslateDemo: View {
    let t: Double
    var body: some View {
        let swap = step(t, 0.25, 0.45)
        HStack(spacing: 30) {
            ZStack {
                Text(verbatim: "Bonjour").opacity(1 - swap)
                Text(verbatim: "Ciao").opacity(swap)
            }
            .font(.system(size: 30, weight: .semibold, design: .rounded)).frame(width: 140)
            Image(systemName: "speaker.wave.2.fill").font(.system(size: 28)).foregroundStyle(.tint)
                .opacity(step(t, 0.5, 0.6)).scaleEffect(1 + 0.08 * sin(t * .pi * 8) * step(t, 0.5, 0.6))
            Image(systemName: "viewfinder").font(.system(size: 34)).foregroundStyle(.secondary).opacity(step(t, 0.7, 0.8))
        }
    }
}

/// Three saved passwords get checked, one turns out to be breached.
private struct PasswordsDemo: View {
    let t: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<3) { i in
                let shown = step(t, 0.2 + Double(i) * 0.15, 0.3 + Double(i) * 0.15)
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.secondary).font(.system(size: 12))
                    Text(verbatim: "••••••••••").font(.system(size: 13, design: .monospaced))
                    Image(systemName: i == 1 ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(i == 1 ? Color.red : Color.green).opacity(shown)
                }
            }
        }
    }
}

/// A Keychain prompt, answered once.
private struct KeychainDemo: View {
    let t: Double
    var body: some View {
        let allow = step(t, 0.45, 0.55)
        VStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.system(size: 30)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Capsule().fill(Color.primary.opacity(0.1)).frame(width: 60, height: 20)
                Capsule().fill(Color.accentColor.opacity(0.4 + 0.6 * allow)).frame(width: 90, height: 20)
                    .overlay(Text(verbatim: "Always Allow").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white))
            }
            Image(systemName: "checkmark.seal.fill").font(.system(size: 22)).foregroundStyle(.green).opacity(step(t, 0.6, 0.7))
        }
    }
}

/// The old name fades into the new one beside the eclipse.
private struct RenameDemo: View {
    let t: Double
    var body: some View {
        let swap = step(t, 0.3, 0.55)
        HStack(spacing: 22) {
            EclipseMark(size: 64, glow: swap)
            ZStack(alignment: .leading) {
                Text(verbatim: "Lumen").strikethrough(swap > 0.05, color: .secondary)
                    .foregroundStyle(.secondary).opacity(1 - swap).offset(y: -18 * swap)
                Text(verbatim: "Tacet").opacity(swap).offset(y: 18 * (1 - swap))
            }
            .font(.system(size: 40, weight: .bold, design: .rounded))
            .frame(width: 150, alignment: .leading)
        }
    }
}

private struct GroupsDemo: View {
    let t: Double
    var body: some View {
        let g = step(t, 0.2, 0.5)
        // Three GitHub tabs (purple) slide together into a group; the other tab moves to the end.
        ZStack {
            RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.6 * g), lineWidth: 1.5)
                .frame(width: 246, height: 38).offset(x: -70)
            Text(verbatim: "GitHub 3").font(.system(size: 11, weight: .bold)).foregroundStyle(.purple).opacity(g).offset(x: -70, y: -30)
            Chip(color: .purple).offset(x: -150)
            Chip(color: .orange).offset(x: -70 + 220 * g)
            Chip(color: .purple).offset(x: 10 - 80 * g)
            Chip(color: .purple).offset(x: 90 - 80 * g)
        }
    }
}

private struct PickingDemo: View {
    let t: Double
    var body: some View {
        let picks = [step(t, 0.1, 0.2), step(t, 0.3, 0.4), step(t, 0.5, 0.6)]
        let merge = step(t, 0.7, 0.85)
        HStack(spacing: 8 - 6 * merge) {
            ForEach(0..<4) { i in
                Chip(color: [.blue, .green, .orange, .pink][i])
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: i < 3 ? 2 * picks[i] : 0))
                    .opacity(i == 3 ? 1 - 0.5 * merge : 1)
            }
        }
        .overlay(alignment: .top) {
            Text("⌘").font(.system(size: 14, weight: .bold)).padding(6)
                .background(Circle().fill(.regularMaterial)).offset(y: -44).opacity(1 - merge)
        }
    }
}

private struct AssistantDemo: View {
    let t: Double
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Capsule().fill(Color.accentColor.opacity(0.25)).frame(width: 180, height: 22).opacity(step(t, 0.05, 0.15))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<3) { i in
                    HStack(spacing: 6) {
                        Image(systemName: ["doc.text", "clock", "play.rectangle"][i]).font(.system(size: 10)).foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.2)).frame(width: 120, height: 5)
                    }
                    .opacity(step(t, 0.2 + Double(i) * 0.12, 0.28 + Double(i) * 0.12))
                }
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.35)).frame(width: [240, 210, 150][i], height: 6)
                        .opacity(step(t, 0.6 + Double(i) * 0.08, 0.7 + Double(i) * 0.08))
                }
            }
            .frame(width: 260, alignment: .leading)
        }
    }
}

private struct AppleDemo: View {
    let t: Double
    var body: some View {
        HStack(spacing: 30) {
            Image(systemName: "laptopcomputer").font(.system(size: 64, weight: .light))
                .overlay { Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(.tint).opacity(0.4 + 0.6 * abs(sin(t * .pi * 2))) }
            Image(systemName: "wifi.slash").font(.system(size: 28)).foregroundStyle(.secondary).opacity(step(t, 0.3, 0.5))
            Image(systemName: "lock.fill").font(.system(size: 28)).foregroundStyle(.green).opacity(step(t, 0.5, 0.7))
        }
    }
}

private struct ReadingDemo: View {
    let t: Double
    var body: some View {
        let save = step(t, 0.3, 0.55)
        HStack(spacing: 40) {
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.5)).frame(width: 90, height: 8)
                RoundedRectangle(cornerRadius: 4).fill(Color.teal.opacity(0.5)).frame(width: 110, height: 40)
                ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.2)).frame(width: 110, height: 5) }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .scaleEffect(1 - 0.5 * save).opacity(1 - 0.6 * save)
            .offset(x: 70 * save)
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 26)).foregroundStyle(.tint)
                HStack(spacing: 6) {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.35)).frame(width: 80, height: 6)
                }
                .opacity(step(t, 0.55, 0.7))
            }
        }
    }
}

private struct CustomizeDemo: View {
    let t: Double
    var body: some View {
        let hide = step(t, 0.25, 0.4)
        let dark = step(t, 0.55, 0.75)
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.6)).frame(width: 220, height: 18 * (1 - hide))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2).opacity(step(t, 0.1, 0.2) * (1 - hide)))
                .opacity(1 - hide)
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 2).fill((dark > 0.5 ? Color.white : Color.black).opacity(0.35)).frame(width: [220, 200, 210, 140][i], height: 6)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 1 - 0.85 * dark)))
    }
}

private struct ExtensionsDemo: View {
    let t: Double
    var body: some View {
        let slide = step(t, 0.15, 0.4)
        let count = Int(step(t, 0.5, 0.9) * 12)
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)).frame(width: 200, height: 26)
            ZStack(alignment: .topTrailing) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 18)).foregroundStyle(.red)
                if count > 0 {
                    Text("\(count)").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 3).background(Capsule().fill(.red)).offset(x: 8, y: -6)
                }
            }
            .offset(y: -60 * (1 - slide)).opacity(slide)
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 18)).foregroundStyle(.tint)
        }
    }
}

private struct FixesDemo: View {
    let t: Double
    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<3) { i in
                Image(systemName: "macwindow").font(.system(size: 40, weight: .light))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 16))
                            .opacity(step(t, 0.2 + Double(i) * 0.15, 0.3 + Double(i) * 0.15))
                    }
            }
        }
    }
}
