import SwiftUI

/// Everything about how one site looks, in one panel: ready-made options, elements picked on the page,
/// and your own CSS and JavaScript. Changes apply to the open page as you make them.
struct SiteCustomizer: View {
    /// The tab showing the site, when opened from a page; nil from Settings.
    var tab: Tab?
    @State private var style: SiteStyle
    @State private var hostField: String
    @State private var showCSS: Bool
    @State private var showJS: Bool
    @State private var jsChanged = false
    private let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    init(host: String?, tab: Tab? = nil) {
        self.tab = tab
        let existing = Settings.shared.siteStyle(for: host)
        let start = existing ?? SiteStyle(host: host.map(SiteStyle.normalizedHost) ?? "")
        _style = State(initialValue: start)
        _hostField = State(initialValue: start.host)
        _showCSS = State(initialValue: !start.css.isEmpty)
        _showJS = State(initialValue: !start.js.isEmpty)
        isNew = host == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section("Appearance") {
                    Picker("Colours", selection: $style.theme) {
                        Text("As the site makes them").tag(SiteStyle.Theme.site)
                        Text("Dark").tag(SiteStyle.Theme.dark)
                    }
                    Picker("Font", selection: $style.font) {
                        Text("The site's").tag(SiteStyle.Font.site)
                        Text("System").tag(SiteStyle.Font.system)
                        Text("Serif").tag(SiteStyle.Font.serif)
                        Text("Monospaced").tag(SiteStyle.Font.mono)
                    }
                    Picker("Page width", selection: $style.width) {
                        Text("The site's").tag(SiteStyle.Width.site)
                        Text("Narrow, for reading").tag(SiteStyle.Width.narrow)
                        Text("Medium").tag(SiteStyle.Width.medium)
                    }
                    Toggle("Hide bars and pop-ups that stay on screen", isOn: $style.hideFloating)
                    Toggle("Hide images and videos", isOn: $style.hideImages)
                    Toggle("Turn off animations", isOn: $style.reduceMotion)
                }
                Section {
                    if style.hidden.isEmpty {
                        Text("Nothing hidden yet.").foregroundStyle(.secondary)
                    }
                    ForEach(style.hidden, id: \.self) { selector in
                        HStack {
                            Text(selector).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                .help(selector)
                            Spacer()
                            Button { style.hidden.removeAll { $0 == selector } } label: { Label("Remove", systemImage: "minus.circle.fill").labelStyle(.iconOnly) }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                                .help("Show it again")
                        }
                    }
                    if canPick {
                        Button {
                            save()
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { tab?.startPickingElements() }
                        } label: {
                            Label("Pick Elements to Hide…", systemImage: "cursorarrow.rays")
                        }
                    }
                } header: {
                    Text("Hidden elements")
                } footer: {
                    Text("Click comment sections, sidebars, banners or anything else on the page to hide them on this site.")
                }
                Section {
                    DisclosureGroup("Custom CSS", isExpanded: $showCSS) {
                        CodeEditor(text: $style.css, placeholder: "#comments, .sidebar { display: none !important; }")
                    }
                    DisclosureGroup("Custom JavaScript", isExpanded: $showJS) {
                        CodeEditor(text: $style.js, placeholder: "document.querySelector('video')?.pause();")
                        Label("Runs in the page on this site every time it loads, with access to everything on it. Only add code you wrote or trust.",
                              systemImage: "exclamationmark.shield")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Advanced")
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 520, height: 640)
        .onChange(of: style) { old, new in
            if old.js != new.js { jsChanged = true }
            if !isNew { save() }
        }
    }

    private var canPick: Bool {
        guard let tab, !isNew else { return false }
        return style.matches(tab.host) && !tab.isReader
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = Favicons.shared.cached(style.host) ?? (style.matches(tab?.host) ? tab?.favicon : nil) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "paintbrush").frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Customize Site").font(.headline)
                if isNew {
                    TextField("Site, for example youtube.com", text: $hostField).textFieldStyle(.roundedBorder).frame(width: 260)
                } else {
                    Text(style.host).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isNew {
                Toggle("On", isOn: $style.enabled).toggleStyle(.switch).labelsHidden()
                    .help(style.enabled ? "Turn off this site's changes" : "Turn on this site's changes")
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if !isNew {
                Button("Reset Site", role: .destructive) {
                    let id = style.id
                    Settings.shared.siteStyles.removeAll { $0.id == id }
                    dismiss()
                }
            }
            Spacer()
            if jsChanged, let tab, tab.url != nil, style.matches(tab.host) {
                Button("Reload Page") { tab.reload() }
                    .help("Your JavaScript runs when the page loads")
            }
            if isNew {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    style.host = SiteStyle.normalizedHost(hostField)
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!SiteStyle.normalizedHost(hostField).contains("."))
            } else {
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func save() {
        guard !style.host.isEmpty else { return }
        Settings.shared.saveSiteStyle(style)
    }
}

/// A plain code field with a placeholder.
struct CodeEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .autocorrectionDisabled()
            .frame(minHeight: 110)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                        .padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            .padding(.vertical, 4)
    }
}
