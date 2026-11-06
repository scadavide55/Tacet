import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// First-launch setup, organised in sections with a sidebar, and a tour of Tacet.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, switchOver, importData, google, passwords, theme, icon, background, tabs, search, shield, assistant, tour, shortcuts, done

        var section: Section {
            switch self {
            case .welcome: .welcome
            case .switchOver, .importData, .google, .passwords: .moveIn
            case .theme, .icon, .background, .tabs: .look
            case .search, .shield, .assistant: .privacy
            case .tour, .shortcuts: .learn
            case .done: .done
            }
        }
    }

    enum Section: Int, CaseIterable {
        case welcome, moveIn, look, privacy, learn, done

        var title: LocalizedStringKey {
            switch self {
            case .welcome: "Welcome"
            case .moveIn: "Move in"
            case .look: "Look and feel"
            case .privacy: "Search and privacy"
            case .learn: "Learn Tacet"
            case .done: "Ready"
            }
        }

        var symbol: String {
            switch self {
            case .welcome: "hand.wave"
            case .moveIn: "shippingbox"
            case .look: "paintpalette"
            case .privacy: "shield.lefthalf.filled"
            case .learn: "sparkles"
            case .done: "checkmark.seal"
            }
        }

        var steps: [Step] { Step.allCases.filter { $0.section == self } }
    }

    @Environment(\.dismiss) private var dismiss
    @Bindable private var s = Settings.shared
    @State private var step = Step.welcome
    @State private var forward = true

    private var fullBleed: Bool { step == .welcome || step == .done }

    var body: some View {
        HStack(spacing: 0) {
            if !fullBleed {
                SetupSidebar(current: step) { target in
                    forward = target.rawValue > step.rawValue
                    withAnimation(.easeInOut(duration: 0.3)) { step = target }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                ZStack {
                    content
                        .id(step)
                        .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                                removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                if !fullBleed {
                    Divider()
                    HStack(spacing: 12) {
                        Button("Back") { go(-1) }
                        Spacer()
                        Button("Skip Setup") { finish() }.buttonStyle(.borderless)
                        Button("Continue") { go(1) }
                            .keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 24)
                    .frame(height: 60)
                }
            }
        }
        .frame(width: 900, height: 640)
        .animation(.easeInOut(duration: 0.35), value: fullBleed)
        .tint(s.accent)
        .interactiveDismissDisabled()
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStep(start: { go(1) }, skip: finish)
        case .switchOver: SwitchStep()
        case .importData: ImportStep()
        case .google: GoogleStep()
        case .passwords: PasswordsStep()
        case .theme: ThemeStep()
        case .icon: IconStep()
        case .background: BackgroundStep()
        case .tabs: TabsStep()
        case .search: SearchStep()
        case .shield: ShieldStep()
        case .assistant: AssistantSetupStep()
        case .tour: TourStep()
        case .shortcuts: ShortcutsStep()
        case .done: DoneStep(finish: finish)
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(.easeInOut(duration: 0.32)) { step = next }
    }

    private func finish() {
        s.onboarded = true
        s.aiIntroduced = true
        s.welcomedVersion = UpdateChecker.currentVersion
        dismiss()
    }
}

/// Sections of the setup, with the current one highlighted and finished ones ticked.
private struct SetupSidebar: View {
    let current: OnboardingView.Step
    let jump: (OnboardingView.Step) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                Text("Tacet Setup").font(.system(size: 14, weight: .semibold))
            }
            .padding(.bottom, 18)
            ForEach(OnboardingView.Section.allCases.filter { $0 != .welcome && $0 != .done }, id: \.self) { section in
                let isCurrent = current.section == section
                let isDone = current.section.rawValue > section.rawValue
                Button { jump(section.steps[0]) } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(isCurrent ? Color.accentColor : (isDone ? Color.green.opacity(0.85) : Color.primary.opacity(0.08)))
                                .frame(width: 26, height: 26)
                            Image(systemName: isDone ? "checkmark" : section.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isCurrent || isDone ? Color.white : Color.secondary)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.title).font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                            if isCurrent {
                                let index = section.steps.firstIndex(of: current) ?? 0
                                Text(String(format: L("Step %lld of %lld"), index + 1, section.steps.count))
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isCurrent ? Color.accentColor.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(.easeOut(duration: 0.2), value: current)
            }
            Spacer()
            ProgressView(value: Double(current.rawValue), total: Double(OnboardingView.Step.allCases.count - 1))
                .tint(.accentColor)
        }
        .padding(18)
        .frame(width: 230)
        .frame(maxHeight: .infinity)
        .background(VisualEffect(material: .sidebar, blending: .withinWindow))
    }
}

// MARK: - Layout helpers

/// Header with an icon that springs in, then the title and content fade up one after the other.
private struct StepPage<Content: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let content: Content
    @State private var shown = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 62, height: 62)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .scaleEffect(shown ? 1 : 0.5)
                        .rotationEffect(.degrees(shown ? 0 : -14))
                        .opacity(shown ? 1 : 0)
                    Text(title).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center)
                        .offset(y: shown ? 0 : 10).opacity(shown ? 1 : 0)
                    Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 560).fixedSize(horizontal: false, vertical: true)
                        .offset(y: shown ? 0 : 10).opacity(shown ? 1 : 0)
                }
                content
                    .offset(y: shown ? 0 : 16)
                    .opacity(shown ? 1 : 0)
            }
            .padding(.top, 30)
            .padding(.bottom, 20)
            .padding(.horizontal, 34)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72).delay(0.05)) { shown = true }
        }
    }
}

/// A large selectable card used for themes, layouts and Shield levels.
private struct ChoiceCard<Preview: View>: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey? = nil
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let preview: Preview

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                preview
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 13.5, weight: .semibold))
                        if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A tiny drawing of a browser window, for the theme and layout choices.
private struct MiniWindow: View {
    enum Layout { case left, right, top }
    var layout = Layout.left
    var dark = false

    var body: some View {
        let bg = dark ? Color(white: 0.16) : Color(white: 0.93)
        let chrome = dark ? Color(white: 0.22) : Color(white: 0.85)
        let page = dark ? Color(white: 0.1) : Color.white
        let line = dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
        ZStack {
            bg
            switch layout {
            case .top:
                VStack(spacing: 4) {
                    HStack(spacing: 4) { ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 3).fill(chrome).frame(height: 10) } }
                    RoundedRectangle(cornerRadius: 3).fill(chrome).frame(height: 8)
                    RoundedRectangle(cornerRadius: 5).fill(page)
                }
                .padding(8)
            case .left, .right:
                HStack(spacing: 6) {
                    if layout == .right { RoundedRectangle(cornerRadius: 5).fill(page) }
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.8)).frame(height: 7)
                        ForEach(0..<4) { _ in RoundedRectangle(cornerRadius: 2).fill(line).frame(height: 6) }
                        Spacer()
                    }
                    .frame(width: 44)
                    if layout == .left { RoundedRectangle(cornerRadius: 5).fill(page) }
                }
                .padding(8)
            }
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let start: () -> Void
    let skip: () -> Void
    @State private var language = AppLanguage.current
    @State private var phase = 0
    private let running = Bundle.main.preferredLocalizations.first ?? "en"

    private let features: [(String, LocalizedStringKey)] = [
        ("shield.lefthalf.filled", "Blocks ads and trackers"),
        ("lock.fill", "Private by default"),
        ("bolt.fill", "Fast and light"),
        ("paintbrush.fill", "Yours to customise"),
    ]

    var body: some View {
        ZStack {
            FlowGradient()
            Color.black.opacity(0.3)
            VStack(spacing: 18) {
                Spacer()
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    let pulse = (sin(ctx.date.timeIntervalSinceReferenceDate * 1.6) + 1) / 2
                    EclipseMark(size: 96, glow: pulse)
                        .shadow(color: EclipseMark.coral.opacity(0.35 + 0.3 * pulse), radius: 24 + 16 * pulse)
                }
                .scaleEffect(phase >= 1 ? 1 : 0.2)
                .opacity(phase >= 1 ? 1 : 0)
                Text("Welcome to Tacet").font(.system(size: 40, weight: .bold, design: .rounded))
                    .offset(y: phase >= 2 ? 0 : 20).opacity(phase >= 2 ? 1 : 0)
                Text("A quiet, fast browser that blocks ads and trackers for you. Let's get it set up the way you like. It only takes a minute.")
                    .font(.system(size: 15)).opacity(phase >= 2 ? 0.85 : 0).multilineTextAlignment(.center).frame(maxWidth: 540)
                HStack(spacing: 10) {
                    ForEach(Array(features.enumerated()), id: \.offset) { i, f in
                        Label(f.1, systemImage: f.0)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(Color.white.opacity(0.16), in: Capsule())
                            .offset(y: phase >= 3 ? 0 : 14)
                            .opacity(phase >= 3 ? 1 : 0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.75).delay(Double(i) * 0.08), value: phase)
                    }
                }
                .padding(.top, 6)
                Spacer()
                VStack(spacing: 12) {
                    Button(action: start) {
                        Text("Get Started").font(.system(size: 15, weight: .semibold)).frame(width: 220, height: 40)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .keyboardShortcut(.defaultAction)
                    HStack(spacing: 14) {
                        Picker("Language", selection: $language) {
                            ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                        }
                        .frame(width: 220)
                        .onChange(of: language) { _, l in l.apply() }
                        Button("Skip Setup", action: skip).buttonStyle(.plain).opacity(0.8)
                    }
                    if needsRestart {
                        HStack(spacing: 8) {
                            Text("Restart Tacet to use the new language.").font(.callout)
                            Button("Restart Now") { AppLanguage.relaunch() }
                        }
                    }
                }
                .offset(y: phase >= 4 ? 0 : 20)
                .opacity(phase >= 4 ? 1 : 0)
                .padding(.bottom, 34)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 40)
        }
        .onAppear {
            for i in 1...4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + Double(i - 1) * 0.28) {
                    withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) { phase = i }
                }
            }
        }
    }

    private var needsRestart: Bool {
        let wanted = language == .system ? (Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en") : language.rawValue
        let supported = ["en", "it", "fr"].contains(wanted) ? wanted : "en"
        return supported != running
    }
}

private struct SwitchStep: View {
    @State private var isDefault = DefaultBrowser.isDefault
    @State private var declined = false

    var body: some View {
        StepPage(symbol: "arrow.left.arrow.right", title: "Make Tacet your default browser?",
                 subtitle: "Links from Mail, Messages and every other app will open in Tacet. You can change this anytime in System Settings.") {
            VStack(spacing: 14) {
                if isDefault {
                    Label("Tacet is your default browser", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.green)
                } else if declined {
                    Text("No problem. Your current browser stays the default.").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 12) {
                        Button("Not Now") { declined = true }.controlSize(.large)
                        Button("Yes, Use Tacet") {
                            DefaultBrowser.makeDefault { isDefault = DefaultBrowser.isDefault }
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                    }
                    Text("macOS will ask you to confirm.").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("Your bookmarks, history and sign-ins can come with you in the next step.", systemImage: "square.and.arrow.down")
                    Label("Everything stays on your Mac. Tacet has no accounts and no analytics.", systemImage: "lock")
                    Label("You can change any choice later in Settings.", systemImage: "gearshape")
                }
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .padding(18)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 10)
            }
        }
        .onAppear { isDefault = DefaultBrowser.isDefault }
    }
}

private struct ImportStep: View {
    @State private var sources: [BrowserSource] = []
    @State private var chosen: Set<String> = []
    @State private var options = ImportOptions()
    @State private var working = false
    @State private var lines: [(String, ImportResult)] = []

    var body: some View {
        StepPage(symbol: "square.and.arrow.down.on.square", title: "Bring everything with you",
                 subtitle: "Tacet found these browsers on your Mac. Pick the ones to import from.") {
            VStack(spacing: 12) {
                if sources.isEmpty {
                    Text("No other browsers found. You can skip this step.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            ForEach(sources) { src in
                                let on = chosen.contains(src.id)
                                Button {
                                    if on { chosen.remove(src.id) } else { chosen.insert(src.id) }
                                } label: {
                                    HStack(spacing: 8) {
                                        Group {
                                            if let icon = src.icon { Image(nsImage: icon).resizable() } else { Image(systemName: "globe").resizable() }
                                        }
                                        .frame(width: 26, height: 26)
                                        Text(src.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                    }
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(on ? 0.07 : 0.03)))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 130)
                    HStack(spacing: 18) {
                        Toggle("Bookmarks", isOn: $options.bookmarks)
                        Toggle("History", isOn: $options.history)
                        Toggle("Sign-ins (cookies)", isOn: $options.cookies)
                        if sources.contains(where: { chosen.contains($0.id) && $0.bundleID == ArcImport.bundleID }) {
                            Toggle("Arc Spaces and pinned tabs", isOn: $options.arcSidebar)
                        }
                    }
                    .toggleStyle(.checkbox)
                    HStack(spacing: 10) {
                        Button("Import") { runImport() }
                            .controlSize(.large)
                            .disabled(working || chosen.isEmpty || !(options.bookmarks || options.history || options.cookies || options.arcSidebar))
                        if working { ProgressView().controlSize(.small) }
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        ImportLine(name: line.0, result: line.1)
                    }
                    Text("Chrome, Opera and other Chromium browsers keep sign-ins locked in your Keychain: when macOS asks, choose Allow. Passwords aren't imported.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
                }
            }
        }
        .onAppear {
            guard sources.isEmpty else { return }
            sources = BrowserImporter.detect()
            if let first = sources.first(where: { $0.kind != .safari }) ?? sources.first { chosen = [first.id] }
        }
    }

    private func runImport() {
        let queue = sources.filter { chosen.contains($0.id) }.flatMap { src in src.profiles.map { (src, $0) } }
        working = true
        lines = []
        func next(_ i: Int) {
            guard i < queue.count else { working = false; return }
            let (src, profile) = queue[i]
            BrowserImporter.run(src, profile: profile, options: options) { r in
                let name = src.profiles.count > 1 ? "\(src.name) (\(profile.name))" : src.name
                lines.append((name, r))
                next(i + 1)
            }
        }
        next(0)
    }
}

private struct ImportLine: View {
    let name: String
    let result: ImportResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if result.warnings.isEmpty || result.imported > 0 {
                Label(name + ": " + result.summary, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if result.needsFullDiskAccess {
                HStack {
                    Label("\(name) needs Full Disk Access.", systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .controlSize(.small)
                }
                Text("Turn on Tacet in the list. When you come back to Tacet, the import finishes by itself.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(result.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
        }
        .font(.callout)
    }
}

private struct GoogleStep: View {
    @State private var signedIn: Bool?
    @State private var showSignIn = false

    var body: some View {
        StepPage(symbol: "person.crop.circle.badge.checkmark", title: "Sign in to Google",
                 subtitle: "Sign in once and you're signed in to Gmail, YouTube, Drive and every Google service in Tacet.") {
            VStack(spacing: 14) {
                switch signedIn {
                case .none:
                    ProgressView()
                case .some(true):
                    Label("You're already signed in to Google.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.green)
                    Text("Your Google sign-in came across with your imported data.").foregroundStyle(.secondary)
                case .some(false):
                    Button {
                        showSignIn = true
                    } label: {
                        Label("Sign in with Google", systemImage: "g.circle.fill").font(.system(size: 14, weight: .semibold))
                    }
                    .controlSize(.large)
                    Text("Optional. Tacet never sees your password: you type it on Google's own page.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: check)
        .sheet(isPresented: $showSignIn, onDismiss: check) { GoogleSignInSheet() }
    }

    private func check() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let names: Set<String> = ["SID", "__Secure-1PSID", "__Secure-3PSID", "SAPISID"]
            signedIn = cookies.contains { $0.domain.hasSuffix("google.com") && names.contains($0.name) }
        }
    }
}

/// Google's sign-in page in a sheet, sharing Tacet's cookies. Closes itself once signed in.
private struct GoogleSignInSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("accounts.google.com", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            GoogleWebView { dismiss() }
        }
        .frame(width: 480, height: 640)
    }
}

private struct GoogleWebView: NSViewRepresentable {
    let onSignedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = UserAgent.applicationName
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmyaccount.google.com%2F")!))
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSignedIn: () -> Void
        init(_ f: @escaping () -> Void) { onSignedIn = f }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if webView.url?.host == "myaccount.google.com" { onSignedIn() }
        }
    }
}

private struct PasswordsStep: View {
    @Bindable private var s = Settings.shared
    @State private var managers: [ExternalPasswordManager] = []
    @State private var imported: Int?

    var body: some View {
        StepPage(symbol: "key.fill", title: "Your passwords",
                 subtitle: "Tacet keeps the passwords you save in it in your Mac's Keychain and asks for Touch ID before filling them. It can't see the ones saved in Safari: bring them over below. Already use another password manager? Pick it here.") {
            VStack(spacing: 14) {
                VStack(spacing: 8) {
                    ManagerRow(name: L("Tacet (Keychain and Touch ID)"), detail: L("Saves and fills passwords for you. Recommended."),
                               icon: Image(systemName: "key.fill"), selected: s.passwordManager.isEmpty) { s.passwordManager = "" }
                    ForEach(managers) { m in
                        ManagerRow(name: m.name, detail: detail(m), icon: Image(nsImage: m.icon), selected: s.passwordManager == m.id) {
                            s.passwordManager = m.id
                        }
                    }
                }
                .frame(width: 560)
                if s.passwordManager.isEmpty {
                    HStack(spacing: 10) {
                        Button("Import from Apple Passwords…") { importCSV() }
                        if let imported { Text(String(format: L("Imported %lld passwords."), imported)).foregroundStyle(.green) }
                    }
                    Text("In the Passwords app choose File › Export All Passwords, then pick that file here. Apple doesn't let other browsers read Passwords directly.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 540)
                }
            }
        }
        .onAppear { managers = ExternalPasswordManager.detect() }
    }

    private func detail(_ m: ExternalPasswordManager) -> String {
        switch m.fill {
        case .shortcut(let keys) where !keys.isEmpty: String(format: L("Fill any sign-in page with %@. Tacet won't offer to save passwords."), keys)
        case .shortcut: L("Fill sign-in pages with its Auto-Type shortcut. Tacet won't offer to save passwords.")
        case .openApp: L("Tacet opens it from sign-in pages so you can copy passwords. Tacet won't offer to save passwords.")
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        imported = PasswordStore.shared.importCSV(String(decoding: data, as: UTF8.self))
    }
}

private struct ManagerRow: View {
    let name: String
    let detail: String
    let icon: Image
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon.resizable().aspectRatio(contentMode: .fit).frame(width: 26, height: 26).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13.5, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(selected ? 0.07 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ThemeStep: View {
    @Bindable private var s = Settings.shared
    private let presets = ["#5E5CE6", "#0A84FF", "#30B0C7", "#34C759", "#E8A33D", "#FF6B35", "#FF375F", "#BF5AF2"]

    var body: some View {
        StepPage(symbol: "paintpalette", title: "Pick your look", subtitle: "Choose light or dark, and a colour for Tacet's accents.") {
            VStack(spacing: 20) {
                HStack(spacing: 14) {
                    ChoiceCard(title: "System", detail: "Follows your Mac", selected: s.theme == .system, action: { s.theme = .system }) {
                        HStack(spacing: 0) { MiniWindow(dark: false); MiniWindow(dark: true) }
                    }
                    ChoiceCard(title: "Light", selected: s.theme == .light, action: { s.theme = .light }) { MiniWindow(dark: false) }
                    ChoiceCard(title: "Dark", selected: s.theme == .dark, action: { s.theme = .dark }) { MiniWindow(dark: true) }
                }
                HStack(spacing: 12) {
                    ForEach(presets, id: \.self) { hex in
                        Circle().fill(Color(hex: hex)).frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.primary, lineWidth: s.accentHex.uppercased() == hex ? 2 : 0).padding(-4))
                            .onTapGesture { s.accentHex = hex }
                    }
                    ColorPicker("", selection: s.accentBinding, supportsOpacity: false).labelsHidden()
                }
                Picker("Window style", selection: $s.chromeStyle) {
                    ForEach(ChromeStyle.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
            }
        }
    }
}

private struct IconStep: View {
    var body: some View {
        StepPage(symbol: "app.badge", title: "Choose an icon",
                 subtitle: "The one in your Dock and in Finder. Seal, corona is Tacet's own; the others are its alternatives. You can change it later in Settings › Appearance.") {
            AppIconPicker(tile: 64).frame(width: 640)
        }
    }
}

private struct BackgroundStep: View {
    var body: some View {
        StepPage(symbol: "photo.on.rectangle.angled", title: "Choose a start page",
                 subtitle: "Pick a gradient, let it move, or use your own photo or a short video.") {
            BackgroundPicker().frame(width: 560)
        }
    }
}

private struct TabsStep: View {
    @Bindable private var s = Settings.shared

    var body: some View {
        StepPage(symbol: "rectangle.3.group", title: "Arrange your tabs",
                 subtitle: "Vertical tabs give long titles room to breathe. Separate and Compact feel like Safari.") {
            VStack(spacing: 18) {
                TabLayoutPicker()
                if s.tabLayout == .vertical {
                    Picker("Sidebar position", selection: $s.sidebarSide) {
                        ForEach(SidebarSide.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Toggle("Group tabs from the same site automatically", isOn: $s.organizeTabs)
                    Toggle("Open the command bar on every new tab", isOn: $s.paletteOnNewTab)
                    Toggle("Float pages with rounded corners", isOn: $s.insetContent)
                    Toggle("Hibernate tabs you haven't used for 15 minutes to save memory", isOn: Binding(
                        get: { s.hibernateMinutes > 0 }, set: { s.hibernateMinutes = $0 ? 15 : 0 }))
                    Text("Tip: drag a tab onto another one to make a group.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 520, alignment: .leading)
            }
        }
    }
}

private struct SearchStep: View {
    @Bindable private var s = Settings.shared

    var body: some View {
        StepPage(symbol: "magnifyingglass", title: "Choose your search engine", subtitle: "What you type in the command bar is searched here. Private options are marked.") {
            VStack(spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(SearchEngine.allCases.filter { $0 != .custom }) { engine in
                        let on = s.engine == engine
                        Button { s.engine = engine } label: {
                            HStack {
                                Text(engine.name).font(.system(size: 14, weight: .medium))
                                if [.duckduckgo, .brave, .startpage, .kagi].contains(engine) {
                                    Text("Private").font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.green.opacity(0.18), in: Capsule()).foregroundStyle(.green)
                                }
                                Spacer()
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(on ? 0.07 : 0.03)))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Color.accentColor : .clear, lineWidth: 2))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 520)
                Toggle("Show search suggestions as I type", isOn: $s.suggestions)
                    .disabled(s.engine.suggestTemplate == nil)
            }
        }
    }
}

private struct ShieldStep: View {
    @Bindable private var s = Settings.shared

    private enum Level { case off, standard, strict }
    private var level: Level { !s.adBlock ? .off : (s.easyList && s.easyPrivacy ? .strict : .standard) }

    var body: some View {
        StepPage(symbol: "shield.lefthalf.filled", title: "Set up Tacet Shield",
                 subtitle: "Shield stops ads and trackers before they load, using the content blocker built into WebKit. Pages load faster, and you can switch it off for any site from the shield button.") {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    ChoiceCard(title: "Standard", detail: "Built-in list. Works offline, breaks almost nothing.", selected: level == .standard,
                               action: { s.adBlock = true; s.easyList = false; s.easyPrivacy = false }) { ShieldArt(bars: 2) }
                    ChoiceCard(title: "Strict", detail: "Adds EasyList and EasyPrivacy: tens of thousands of rules, updated weekly.", selected: level == .strict,
                               action: { s.adBlock = true; s.easyList = true; s.easyPrivacy = true }) { ShieldArt(bars: 3) }
                    ChoiceCard(title: "Off", detail: "No blocking. You can turn it on anytime with ⇧⌘B.", selected: level == .off,
                               action: { s.adBlock = false }) { ShieldArt(bars: 0) }
                }
                HStack(spacing: 18) {
                    Toggle("Hide cookie banners", isOn: $s.hideCookieBanners)
                    Toggle("Skip YouTube ads", isOn: $s.youtubeAds)
                    Toggle("Block third-party cookies", isOn: $s.blockThirdPartyCookies)
                    Toggle("Clean tracking from links", isOn: $s.stripTracking)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12.5))
                .disabled(!s.adBlock)
            }
        }
    }
}

private struct AssistantSetupStep: View {
    @Bindable private var s = Settings.shared
    @State private var key = ""

    var body: some View {
        StepPage(symbol: "sparkles", title: "Tacet Assistant",
                 subtitle: "Ask questions about the page you're reading, get summaries and explanations, in a panel beside the page. It uses your own API key, and it stays off unless you turn it on.") {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    ChoiceCard(title: "Turn on", detail: "Open it with ⇧⌘A or the sparkles button. You can turn it off in Settings › AI.",
                               selected: s.aiEnabled, action: { s.aiEnabled = true }) { AssistantArt(on: true) }
                    ChoiceCard(title: "Not now", detail: "Nothing is sent anywhere. You can turn it on later in Settings › AI.",
                               selected: !s.aiEnabled, action: { s.aiEnabled = false }) { AssistantArt(on: false) }
                }
                .frame(maxWidth: 520)
                if s.aiEnabled {
                    HStack(spacing: 10) {
                        Picker("Provider", selection: $s.aiProvider) {
                            ForEach(AIProvider.allCases) { Text($0.name).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        if !s.aiProvider.isLocal && s.aiProvider != .apple {
                            SecureField(s.aiProvider.needsKey ? "API key" : "API key (optional)", text: $key)
                                .frame(width: 260)
                                .onChange(of: key) { _, k in AIKeys.set(k, for: s.aiProvider) }
                        }
                    }
                    Text(s.aiProvider.isLocal ? "No key needed: open the app and Tacet finds its models. Pick one in Settings › AI."
                         : s.aiProvider == .custom ? "Set the server address and model in Settings › AI." : "The key is saved in your Keychain. You can change the model in Settings › AI.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: s.aiProvider) {
            // Off the main thread, so the setup doesn't freeze if macOS asks for Keychain access.
            let p = s.aiProvider
            key = await Task.detached(priority: .userInitiated) { AIKeys.get(p) }.value ?? ""
        }
    }
}

private struct AssistantArt: View {
    let on: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(on ? 0.28 : 0.08), Color.accentColor.opacity(0.05)], startPoint: .top, endPoint: .bottom)
            Image(systemName: on ? "sparkles" : "moon.zzz")
                .font(.system(size: 34))
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }
}

private struct ShieldArt: View {
    let bars: Int

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(bars == 0 ? 0.08 : 0.28), Color.accentColor.opacity(0.05)], startPoint: .top, endPoint: .bottom)
            Image(systemName: bars == 0 ? "shield.slash" : "shield.lefthalf.filled")
                .font(.system(size: 34))
                .foregroundStyle(bars == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            if bars > 0 {
                HStack(spacing: 3) {
                    ForEach(0..<3) { i in Capsule().fill(i < bars ? Color.accentColor : Color.primary.opacity(0.15)).frame(width: 14, height: 4) }
                }
                .offset(y: 32)
            }
        }
    }
}

private struct TourStep: View {
    private let items: [(String, LocalizedStringKey, LocalizedStringKey)] = [
        ("command", "Command bar", "Press ⌘L or click the address. Type a site, a search, an open tab, a bookmark or a command."),
        ("sidebar.left", "Sidebar", "Your tabs live here. Drag to reorder, right-click to pin. Hide it with ⌘S; hover the edge to peek."),
        ("pin", "Pinned tabs", "Pinned tabs sit at the top as icons and are always one click away."),
        ("rectangle.split.2x1", "Split view", "Two pages side by side. Right-click a tab and choose Open in Split View."),
        ("doc.plaintext", "Reader", "Click the page icon in the address, or press ⇧⌘R, for a clean reading view."),
        ("shield.lefthalf.filled", "Shield button", "Shows what's blocked and lets you turn protection off for the current site."),
        ("moon.zzz", "Hibernation", "Unused tabs sleep to free memory, then wake up right where you left them."),
        ("eyeglasses", "Private windows", "⇧⌘N opens a window that forgets everything when you close it."),
    ]

    var body: some View {
        StepPage(symbol: "sparkles", title: "How Tacet works", subtitle: "A few things worth knowing.") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(items, id: \.0) { symbol, title, text in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(.tint).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.system(size: 13.5, weight: .semibold))
                            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            // Fits beside the setup sidebar; a fixed wider grid pushed the whole sheet past its edges.
            .frame(maxWidth: 600)
        }
    }
}

struct ShortcutList: View {
    static let groups: [(LocalizedStringKey, [(String, LocalizedStringKey)])] = [
        ("Tabs and windows", [
            ("⌘T", "New tab"), ("⌘W", "Close tab"), ("⇧⌘T", "Reopen closed tab or window"), ("⌘N", "New window"),
            ("⇧⌘N", "New private window"), ("⌃⇥", "Next tab"), ("⌃⇧⇥", "Previous tab"), ("⌘1…⌘9", "Go to tab"),
            ("⇧⌘M", "Mute tab"), ("⌥⌘S", "Split view"),
        ]),
        ("Browsing", [
            ("⌘L / ⌘K", "Command bar"), ("⌘[ / ⌘]", "Back / forward"), ("⌘R", "Reload"), ("⌥⌘R", "Reload ignoring cache"),
            ("⌘F", "Find on page"), ("⌘G", "Find next"), ("⇧⌘R", "Reader"), ("⌘+ / ⌘− / ⌘0", "Zoom"),
            ("⌘D", "Bookmark the page"), ("⇧⌘C", "Copy link"),
        ]),
        ("Tacet", [
            ("⌘S", "Show or hide the sidebar"), ("⇧⌘B", "Ad blocker on or off"), ("⌘Y", "History"),
            ("⌥⌘B", "Bookmarks"), ("⌥⌘L", "Downloads"), ("⇧⌘A", "Tacet Assistant"), ("⇧⌘P", "Tacet Plugins"),
            ("⌥⌘I", "Web Inspector (Developer Mode)"), ("⌥⌘U", "Page source (Developer Mode)"), ("⌘P", "Print"), ("⌘,", "Settings"),
        ]),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 7) {
                    Text(group.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
                    ForEach(Array(group.1.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Text(item.0).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                                .fixedSize()
                            Text(item.1).font(.system(size: 12.5)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ShortcutsStep: View {
    var body: some View {
        StepPage(symbol: "keyboard", title: "Keyboard shortcuts", subtitle: "Everything has a shortcut. You'll find them all in the menus too.") {
            ShortcutList().frame(maxWidth: 600)
        }
    }
}

private struct DoneStep: View {
    let finish: () -> Void
    @Bindable private var s = Settings.shared
    @State private var shown = false

    var body: some View {
        ZStack {
            FlowGradient()
            Color.black.opacity(0.3)
            VStack(spacing: 18) {
                Spacer()
                ZStack {
                    ForEach(0..<3) { i in
                        Circle().stroke(Color.white.opacity(0.25), lineWidth: 2)
                            .frame(width: 110, height: 110)
                            .scaleEffect(shown ? 1.4 + Double(i) * 0.35 : 0.6)
                            .opacity(shown ? 0 : 0.8)
                            .animation(.easeOut(duration: 1.4).delay(Double(i) * 0.2), value: shown)
                    }
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 76)).foregroundStyle(.white)
                        .scaleEffect(shown ? 1 : 0.3)
                        .rotationEffect(.degrees(shown ? 0 : -30))
                }
                Text("You're all set").font(.system(size: 36, weight: .bold, design: .rounded))
                    .opacity(shown ? 1 : 0)
                Text("Press ⌘L to go anywhere. You can see this tour again from the Help menu, and change anything in Settings.")
                    .font(.system(size: 15)).opacity(shown ? 0.85 : 0).multilineTextAlignment(.center).frame(maxWidth: 480)
                HStack(spacing: 8) {
                    chip(s.theme.label, "circle.lefthalf.filled")
                    chip(s.tabLayout.label, "rectangle.3.group")
                    chip(s.engine.name, "magnifyingglass")
                    chip(s.adBlock ? (s.easyList ? L("Strict") : L("Standard")) : L("Off"), "shield.lefthalf.filled")
                }
                .opacity(shown ? 1 : 0)
                Spacer()
                Button(action: finish) {
                    Text("Start Browsing").font(.system(size: 15, weight: .semibold)).frame(width: 220, height: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 40)
                .opacity(shown ? 1 : 0)
            }
            .foregroundStyle(.white)
        }
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.6).delay(0.1)) { shown = true } }
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Color.white.opacity(0.16), in: Capsule())
    }
}
