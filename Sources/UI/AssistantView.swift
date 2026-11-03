import SwiftUI
import UniformTypeIdentifiers

/// The assistant chat, in a panel on the right of the window.
struct AssistantPanel: View {
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared
    var maxWidth: Double = .infinity
    @State private var showHistory = false
    /// The width while the edge is dragged, saved to settings only when the drag ends.
    @State private var dragWidth: Double?
    @State private var dragStart: Double?

    static let minWidth = 340.0
    private var width: Double { min(max(Self.minWidth, dragWidth ?? s.assistantWidth), max(Self.minWidth, maxWidth)) }

    private var chat: AssistantChat { b.assistant }
    private var configured: Bool { !s.aiProvider.needsKey || AIKeys.has(s.aiProvider) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if configured {
                AssistantMessages(chat: chat)
                AssistantComposer(chat: chat)
            } else {
                setup
            }
        }
        .frame(width: width)
        .background(VisualEffect(material: .sidebar, blending: .withinWindow))
        .overlay(alignment: .leading) {
            ZStack(alignment: .leading) {
                Color.clear
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            }
                .frame(width: 7)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            let base = dragStart ?? width
                            if dragStart == nil { dragStart = base }
                            dragWidth = min(max(Self.minWidth, maxWidth), max(Self.minWidth, base - v.translation.width))
                        }
                        .onEnded { _ in
                            if let dragWidth { s.assistantWidth = dragWidth }
                            dragWidth = nil
                            dragStart = nil
                        }
                )
                .help("Drag to resize")
        }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            guard chat.canAttachImages else { return false }
            AssistantComposer.load(providers, into: chat)
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text("Tacet Assistant").font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
            BetaBadge()
            Spacer(minLength: 4)
            IconButton(systemName: "clock.arrow.circlepath", help: "Chat History") { showHistory.toggle() }
                .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                    AssistantHistoryList(chat: chat) { showHistory = false }
                }
            IconButton(systemName: "square.and.pencil", help: "New Chat") { chat.newChat() }
                .disabled(chat.messages.isEmpty && chat.draft.isEmpty)
            IconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Full Screen Chat") { b.assistantExpanded = true }
            IconButton(systemName: "xmark", help: "Close (⇧⌘A)") { b.assistantVisible = false }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(WindowDragArea())
    }

    private var setup: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "key.horizontal").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Add an API key to start").font(.headline)
            Text("Tacet Assistant uses your own key from Anthropic, OpenAI, OpenRouter, DeepSeek or any OpenAI-compatible server. The key stays in your Keychain.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SettingsLink { Text("Open Settings") }
            Spacer()
        }
        .padding(24)
    }
}

// MARK: - Messages

struct AssistantMessages: View {
    var chat: AssistantChat
    /// The conversation's width in the full-window chat; the panel uses all of its width.
    var maxWidth: CGFloat = .infinity
    @Environment(BrowserState.self) var b

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.messages.isEmpty { AssistantSuggestions(chat: chat) }
                    ForEach(chat.messages) { m in
                        // Only the message that changed is drawn again (and its Markdown read again) as a reply streams in.
                        AssistantBubble(message: m, thinking: chat.busy && m.id == chat.messages.last?.id)
                            .equatable()
                            .id(m.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }
}

struct AssistantSuggestions: View {
    var chat: AssistantChat

    private var prompts: [String] {
        if AssistantSources.isVideo(chat.browser?.current?.url) {
            return ["Summarise this video", "What are the key moments, with timestamps?"]
        }
        return chat.pageToAttach != nil
            ? ["Summarise this page", "What are the key points?", "Explain the text I selected"]
            : ["What can you do?", "Explain the text I selected"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about the page you're reading, or anything else.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(prompts, id: \.self) { p in
                Button {
                    chat.draft = L(p)
                    chat.send()
                } label: {
                    Text(LocalizedStringKey(p)).font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }
}

struct AssistantBubble: View {
    let message: AssistantChat.Message
    let thinking: Bool
    @Environment(BrowserState.self) var b

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if let page = message.pageTitle {
                        Label(page, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let quote = message.quote {
                        Text("“\(quote)”").font(.caption).italic().foregroundStyle(.secondary).lineLimit(3)
                            .multilineTextAlignment(.trailing)
                    }
                    if !message.images.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(message.images.enumerated()), id: \.offset) { _, img in
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    if !message.text.isEmpty {
                        Text(message.text).textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.18)))
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(message.activity.enumerated()), id: \.offset) { _, note in
                    Label(note, systemImage: "wand.and.stars").font(.caption).foregroundStyle(.secondary)
                }
                if !message.text.isEmpty {
                    Text(Self.markdown(message.text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else if thinking && message.error == nil {
                    ProgressView().controlSize(.small)
                }
                ForEach(Array(message.links.enumerated()), id: \.offset) { _, link in
                    Button { b.newTab(url: link.url) } label: {
                        Label(link.title, systemImage: "arrow.up.right.square").lineLimit(1)
                    }
                    .help(link.url.absoluteString)
                }
                if !message.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sources").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(message.sources.enumerated()), id: \.offset) { _, source in
                            Button { b.newTab(url: source.url) } label: {
                                Text(source.title).font(.caption).lineLimit(1).truncationMode(.tail)
                            }
                            .buttonStyle(.link)
                            .help(source.url.absoluteString)
                        }
                    }
                    .padding(.top, 2)
                }
                if let error = message.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
            }
            .contextMenu {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                }
            }
        }
    }

    /// Inline Markdown (bold, italics, code, links), keeping the model's line breaks.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

extension AssistantBubble: Equatable {
    /// What the bubble shows; images and links are only ever added, so their counts are enough.
    static func == (lhs: Self, rhs: Self) -> Bool {
        let l = lhs.message, r = rhs.message
        return lhs.thinking == rhs.thinking && l.id == r.id && l.text == r.text && l.activity == r.activity
            && l.error == r.error && l.links.count == r.links.count && l.sources.count == r.sources.count
            && l.images.count == r.images.count && l.pageTitle == r.pageTitle && l.quote == r.quote
    }
}

// MARK: - Composer

struct AssistantComposer: View {
    @Bindable var chat: AssistantChat
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if chat.pageToAttach != nil || !chat.images.isEmpty || chat.selection != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let selection = chat.selection {
                            chip(title: "“" + AssistantChat.quote(selection) + "”", icon: nil, symbol: "text.quote",
                                 help: "The selected text is sent with your next message") { chat.selection = nil }
                        }
                        if let page = chat.pageToAttach {
                            chip(title: page.title, icon: page.favicon) { chat.removePageAttachment() }
                        }
                        ForEach(chat.images) { img in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: img.image).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                                Button { chat.images.removeAll { $0.id == img.id } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove")
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                if chat.canAttachImages {
                    IconButton(systemName: "photo.badge.plus", help: "Attach Image") { pickImages() }
                }
                TextField(L("Ask Tacet Assistant…"), text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        // After the key is handled, so the field shows the emptied draft.
                        DispatchQueue.main.async { chat.send() }
                        return .handled
                    }
                    .padding(.vertical, 5)
                if chat.busy {
                    IconButton(systemName: "stop.circle.fill", help: "Stop", tint: .accentColor, size: 16) { chat.stop() }
                } else {
                    IconButton(systemName: "arrow.up.circle.fill", help: "Send", tint: .accentColor, size: 16) { chat.send() }
                        .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.images.isEmpty)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
            HStack(spacing: 6) {
                WebAccessButton()
                BrowserUseButton()
                Spacer(minLength: 4)
                ChatModelMenu(chat: chat)
            }
            Text("Answers come from your AI provider and can be wrong.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .onAppear { focused = true }
    }

    private func chip(title: String, icon: NSImage?, symbol: String = "doc.text",
                      help: LocalizedStringKey = "This page is sent with your next message", remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            if let icon { Image(nsImage: icon).resizable().frame(width: 12, height: 12) } else { Image(systemName: symbol).font(.caption) }
            Text(title).font(.caption).lineLimit(1).frame(maxWidth: 200, alignment: .leading)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Don't attach this page")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .help(help)
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let img = NSImage(contentsOf: url) { chat.addImage(img) } }
    }

    static func load(_ providers: [NSItemProvider], into chat: AssistantChat) {
        for p in providers {
            if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage { DispatchQueue.main.async { chat.addImage(img) } }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url, let img = NSImage(contentsOf: url) { DispatchQueue.main.async { chat.addImage(img) } }
                }
            }
        }
    }
}

/// Past chats, newest first, to reopen or delete.
struct AssistantHistoryList: View {
    var chat: AssistantChat
    var close: () -> Void
    @Environment(BrowserState.self) var b
    private var history = AssistantHistory.shared
    @State private var query = ""
    @State private var confirmClear = false

    init(chat: AssistantChat, close: @escaping () -> Void) {
        self.chat = chat
        self.close = close
    }

    private var shown: [AssistantHistory.Summary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? history.chats : history.chats.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Chat History").font(.headline)
                Spacer()
                if !history.chats.isEmpty {
                    Button("Delete All…") { confirmClear = true }.buttonStyle(.link).font(.caption)
                }
            }
            if history.chats.count > 6 {
                TextField("Search chats", text: $query).textFieldStyle(.roundedBorder)
            }
            if b.isPrivate {
                Text("Chats in private windows aren't saved.").font(.caption).foregroundStyle(.secondary)
            }
            if history.chats.isEmpty {
                Text("No saved chats yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { c in AssistantHistoryRow(summary: c, chat: chat, opened: close) }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(12)
        .frame(width: 320)
        .confirmationDialog("Delete all saved chats?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { history.clear() }
        } message: {
            Text("This can't be undone.")
        }
    }
}

/// A small switch below the chat box, tinted when on.
struct ChatSwitch: View {
    let title: LocalizedStringKey
    let symbol: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06)))
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// Turns the assistant's web search and fetch on and off from the chat.
struct WebAccessButton: View {
    @Bindable private var s = Settings.shared

    var body: some View {
        ChatSwitch(title: "Web access", symbol: "globe", on: s.aiWeb) { s.aiWeb.toggle() }
            .help(s.aiWeb ? "The assistant can search the web and read pages. Click to turn off." : "Let the assistant search the web and read pages")
    }
}

/// Turns page control on and off from the chat. The first time, it explains what that means.
struct BrowserUseButton: View {
    @Bindable private var s = Settings.shared
    @State private var explaining = false

    var body: some View {
        ChatSwitch(title: "Browser use", symbol: "cursorarrow.click.2", on: s.aiControl) {
            if s.aiControl { s.aiControl = false } else if s.aiControlExplained { s.aiControl = true } else { explaining = true }
        }
        .help(s.aiControl ? "The assistant can click, type and scroll on the current page. Click to turn off." : "Let the assistant click, type and scroll on the current page")
        .alert("Turn on browser use?", isPresented: $explaining) {
            Button("Turn On") {
                s.aiControlExplained = true
                s.aiControl = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("When you ask, the assistant can use the page in the current tab for you, where you're signed in. It asks before sending, buying or deleting anything, and never fills in passwords or card numbers. A page can try to trick it, so watch what it does and press Stop if needed.")
        }
    }
}

/// The model for this chat, from the provider's list.
struct ChatModelMenu: View {
    var chat: AssistantChat
    private var models = AIModels.shared
    private var s = Settings.shared

    init(chat: AssistantChat) { self.chat = chat }

    var body: some View {
        let list = models.models(for: s.aiProvider)
        let current = list.first { $0.id == chat.model }?.name ?? chat.model
        Menu {
            ForEach(list) { m in
                Button { chat.model = m.id } label: {
                    if m.id == chat.model { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                }
            }
            if list.isEmpty { Text(models.loading.contains(s.aiProvider) ? "Loading models…" : "No models loaded") }
            Divider()
            Button("Refresh List") { models.refresh(s.aiProvider, force: true) }
        } label: {
            Text(current).font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 130)
        .help("Model for this chat")
        .onAppear { models.refresh(s.aiProvider) }
    }
}

struct BetaBadge: View {
    var body: some View {
        Text("Beta").font(.system(size: 9.5, weight: .bold)).textCase(.uppercase)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .foregroundStyle(.tint)
    }
}

/// Opens and closes the assistant panel; shown only when the assistant is turned on.
struct AssistantButton: View {
    @Environment(BrowserState.self) var b
    private var s = Settings.shared

    var body: some View {
        if s.aiEnabled {
            IconButton(systemName: "sparkles", help: "Tacet Assistant (⇧⌘A)", tint: b.assistantVisible ? .accentColor : nil) {
                b.assistantVisible.toggle()
            }
        }
    }
}

// MARK: - Introduction

/// Shown once to people who used Tacet before the assistant existed.
struct AssistantIntro: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .medium)).foregroundStyle(.tint)
                .frame(width: 62, height: 62)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("New: Tacet Assistant").font(.system(size: 22, weight: .bold))
                    BetaBadge()
                }
                Text("An AI assistant in a panel beside the page, for questions about what you're reading.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 10) {
                feature("doc.text.magnifyingglass", "Summaries and answers about the page you have open")
                feature("photo", "Images too, with models that can read them")
                feature("key", "Your own key: Anthropic, OpenAI, OpenRouter, DeepSeek, or a model on your Mac with Ollama")
                feature("hand.raised", "Off until you turn it on. Nothing is sent until you ask something")
            }
            .frame(maxWidth: 420, alignment: .leading)
            HStack(spacing: 10) {
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Turn On…") {
                    Settings.shared.aiEnabled = true
                    dismiss()
                    openSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            Text("You can change this anytime in Settings › AI.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(width: 500)
    }

    private func feature(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Settings

struct AIPane: View {
    @Bindable private var s = Settings.shared
    @State private var key = ""
    @State private var saved = false

    private var modelBinding: Binding<String> {
        Binding(get: { s.aiModelName },
                set: { var m = s.aiModels; m[s.aiProvider.rawValue] = $0; s.aiModels = m })
    }

    private var visionBinding: Binding<Bool> {
        Binding(get: { s.aiProvider.supportsImages(s.aiModelName) },
                set: { var v = s.aiVision; v[s.aiProvider.visionKey(s.aiModelName)] = $0; s.aiVision = v })
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $s.aiEnabled) {
                    HStack(spacing: 6) { Text("Turn on Tacet Assistant"); BetaBadge() }
                }
                Text("Tacet Assistant answers questions about the page you're reading in a panel on the right (⇧⌘A). It is off unless you turn it on, and nothing is sent until you ask something.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Provider") {
                Picker("Provider", selection: $s.aiProvider) {
                    ForEach(AIProvider.allCases) { Text($0.name).tag($0) }
                }
                if s.aiProvider == .apple {
                    AppleModelNotice()
                }
                if s.aiProvider.isLocal {
                    LocalServerSettings(provider: s.aiProvider)
                }
                if s.aiProvider == .custom {
                    LabeledContent("Server address") {
                        TextField("", text: $s.aiBaseURL, prompt: Text(AIProvider.custom.defaultBaseURL))
                            .textFieldStyle(.roundedBorder).frame(minWidth: 260)
                            .onSubmit { AIModels.shared.refresh(.custom, force: true) }
                    }
                    Text("Any server that speaks the OpenAI Chat Completions API, such as Ollama or LM Studio.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if s.aiProvider != .apple && !s.aiProvider.isLocal {
                LabeledContent(s.aiProvider.needsKey ? "API key" : "API key (optional)") {
                    HStack {
                        SecureField("", text: $key, prompt: Text("Paste your key here"))
                            .textFieldStyle(.roundedBorder).frame(minWidth: 240)
                            .onSubmit(saveKey)
                        Button(saved ? "Saved" : "Save", action: saveKey).disabled(saved)
                    }
                }
                }
                if s.aiProvider != .apple {
                LabeledContent("Default model") {
                    ModelPicker(provider: s.aiProvider, selection: modelBinding)
                }
                if let error = AIModels.shared.errors[s.aiProvider] {
                    Text(String(format: L("Couldn't load the models: %@"), error)).font(.caption).foregroundStyle(.orange)
                }
                Toggle("This model can read images", isOn: visionBinding)
                }
            }
            Section {
                Picker("Length", selection: $s.aiDetailed) {
                    Text("Short and to the point").tag(false)
                    Text("Detailed").tag(true)
                }
                Toggle("Personality", isOn: $s.aiPersonality)
                if let fast = s.aiProvider.fastModel {
                    Toggle(isOn: $s.aiQuickFast) {
                        Text("Faster answers in the command bar")
                        Text(String(format: L("Uses %@, a smaller model that starts answering sooner."), fast))
                    }
                }
            } header: {
                Text("Answers")
            } footer: {
                Text("With Personality on, Tacet Assistant is calm and direct, with a dry sense of humour now and then. Off, it answers in a neutral voice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Web access: search the web and read pages", isOn: $s.aiWeb)
            } footer: {
                Text(s.aiProvider == .anthropic
                     ? "The assistant can look things up and open pages that appear in the chat. With Anthropic, searches and pages are handled on Anthropic's servers."
                     : "The assistant can look things up and open pages that appear in the chat. Searches go to DuckDuckGo, and pages are downloaded by your Mac without cookies or logins.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Browser use: let the assistant click, type and scroll on pages", isOn: $s.aiControl)
            } footer: {
                Text("When you ask, the assistant can use the page in the current tab for you, where you're signed in. It asks before sending, buying or deleting anything, and never fills in passwords or card numbers. A page can try to trick it, so watch what it does and press Stop if needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("When you ask something, your message, the attached page and any images are sent to the provider you chose, under their privacy terms. With a server on your own Mac, such as Ollama, nothing leaves your computer unless the assistant searches the web. Your API key is kept in the macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadKey()
            AIModels.shared.refresh(s.aiProvider)
        }
        .onChange(of: s.aiProvider) { _, p in
            loadKey()
            AIModels.shared.refresh(p)
        }
        .onChange(of: key) { _, _ in saved = false }
    }

    /// Read off the main thread, so Settings doesn't freeze if macOS asks for Keychain access.
    private func loadKey() {
        let p = s.aiProvider
        Task { @MainActor in
            let found = await Task.detached(priority: .userInitiated) { AIKeys.get(p) }.value
            guard s.aiProvider == p else { return }
            key = found ?? ""
            saved = true
        }
    }

    private func saveKey() {
        AIKeys.set(key, for: s.aiProvider)
        saved = true
        AIModels.shared.refresh(s.aiProvider, force: true)
    }
}

/// What the on-device model can and can't do, and whether this Mac can run it.
struct AppleModelNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = AppleModel.unavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Label("Ready on this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Label {
                Text("Apple's model is free, works offline and nothing leaves your Mac, but it is limited: it is much smaller than cloud models, makes more mistakes, reads only the start of long pages and videos, can't see images, and is less reliable at using pages for you. For long or hard questions, use a cloud provider.")
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Chooses one of the provider's models from its own list, or takes a typed name when the list can't be loaded.
struct ModelPicker: View {
    let provider: AIProvider
    @Binding var selection: String
    private var models = AIModels.shared

    init(provider: AIProvider, selection: Binding<String>) {
        self.provider = provider
        _selection = selection
    }

    var body: some View {
        let list = models.models(for: provider)
        HStack(spacing: 6) {
            if list.isEmpty {
                if models.loading.contains(provider) {
                    ProgressView().controlSize(.small)
                    Text("Loading models…").foregroundStyle(.secondary)
                } else {
                    TextField("", text: $selection, prompt: Text("Type a model name"))
                        .textFieldStyle(.roundedBorder).frame(minWidth: 200)
                }
            } else {
                Picker("", selection: $selection) {
                    if !list.contains(where: { $0.id == selection }) { Text(selection).tag(selection) }
                    ForEach(list) { m in Text(m.name).tag(m.id) }
                }
                .labelsHidden()
                .frame(minWidth: 200)
            }
            Button { models.refresh(provider, force: true) } label: { Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .help("Refresh List")
                .disabled(models.loading.contains(provider))
        }
    }
}

/// Ollama and LM Studio: no key, an address that's usually right, and what to do when the server isn't on.
struct LocalServerSettings: View {
    let provider: AIProvider
    @Bindable private var s = Settings.shared
    private var models = AIModels.shared

    init(provider: AIProvider) { self.provider = provider }

    var body: some View {
        LabeledContent("Server address") {
            TextField("", text: Binding(get: { s.aiLocalURLs[provider.rawValue] ?? "" },
                                        set: { s.aiLocalURLs[provider.rawValue] = $0 }),
                      prompt: Text(provider.defaultBaseURL))
                .textFieldStyle(.roundedBorder).frame(minWidth: 260)
                .onSubmit { AIModels.shared.refresh(provider, force: true) }
        }
        HStack {
            if models.loading.contains(provider) {
                ProgressView().controlSize(.small)
                Text("Looking for models…").font(.caption).foregroundStyle(.secondary)
            } else if models.errors[provider] == nil, !models.models(for: provider).isEmpty {
                Label(String(format: L("Connected · %d models"), models.models(for: provider).count), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            Spacer()
            Button("Check Again") { AIModels.shared.refresh(provider, force: true) }.controlSize(.small)
            if let url = provider.appURL { Link(String(format: L("Get %@"), provider.name), destination: url).font(.caption) }
        }
        Text(provider == .ollama
             ? "Runs models on your Mac with Ollama: no key, and nothing leaves your Mac unless the assistant searches the web. Download a model with ollama pull, such as ollama pull gemma3 or llama3.2-vision for pictures."
             : "Runs models on your Mac with LM Studio: no key, and nothing leaves your Mac unless the assistant searches the web. Download a model in LM Studio, then start its server in the Developer tab.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
