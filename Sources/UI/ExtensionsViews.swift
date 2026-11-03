import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Toolbar buttons

/// The buttons pinned to the toolbar, next to the extensions menu: web extensions (shown unless unpinned) and the
/// Tacet plugins you pinned. Everything else is one click away in the puzzle menu.
struct ExtensionButtons: View {
    var tab: Tab
    @Environment(BrowserState.self) var b
    private var ext = Extensions.shared
    private var store = PluginStore.shared

    init(tab: Tab) { self.tab = tab }

    var body: some View {
        let _ = ext.revision
        let plugins = store.installed.values.filter { $0.pinned == true && $0.enabled }
            .sorted { L($0.plugin.name).localizedCaseInsensitiveCompare(L($1.plugin.name)) == .orderedAscending }
        HStack(spacing: 2) {
            if #available(macOS 15.4, *), !b.isPrivate {
                ForEach(ext.loaded.filter { $0.item.pinned ?? true }, id: \.item.id) { entry in
                    ExtensionButton(id: entry.item.id, context: entry.context, tab: tab)
                }
            }
            ForEach(plugins, id: \.plugin.id) { item in PluginButton(plugin: item.plugin, tab: tab) }
        }
    }
}

/// A pinned Tacet plugin: its click does what it does in the extensions menu.
struct PluginButton: View {
    let plugin: PluginStore.Plugin
    var tab: Tab
    @State private var showHowTo = false

    var body: some View {
        IconButton(systemName: plugin.icon ?? "puzzlepiece.extension", help: L(plugin.name)) {
            if PluginActions.activate(plugin, enabled: true, tab: tab) == .showHowTo { showHowTo = true }
        }
        .popover(isPresented: $showHowTo, arrowEdge: .bottom) {
            PluginHowTo(plugin: plugin, back: { showHowTo = false }, close: { showHowTo = false }).frame(width: 300)
        }
    }
}

@available(macOS 15.4, *)
struct ExtensionButton: View {
    let id: UUID
    let context: WKWebExtensionContext
    var tab: Tab
    @State private var hover = false

    var body: some View {
        let action = context.action(for: tab)
        let icon = action?.icon(for: CGSize(width: 16, height: 16)) ?? context.webExtension.icon(for: CGSize(width: 16, height: 16))
        let badge = action?.badgeText ?? ""
        Button { context.performAction(for: tab) } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let icon { Image(nsImage: icon).resizable().interpolation(.high) } else { Image(systemName: "puzzlepiece.extension") }
                }
                .frame(width: 16, height: 16)
                .opacity(action?.isEnabled == false ? 0.4 : 1)
                if !badge.isEmpty {
                    Text(badge).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 3).padding(.vertical, 0.5)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 7, y: -6)
                        .fixedSize()
                }
            }
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .background(AnchorView(id: id))
        .help(action?.label.isEmpty == false ? action!.label : (context.webExtension.displayName ?? ""))
        .contextMenu {
            if context.optionsPageURL != nil {
                Button("Extension Settings") { openOptions() }
            }
            SettingsLink { Text("Manage Extensions…") }
        }
    }

    private func openOptions() {
        guard let url = context.optionsPageURL, let b = tab.browser else { return }
        b.newTab(url: url)
    }
}

/// Records the AppKit view under an extension's button, so its popup can point at it.
struct AnchorView: NSViewRepresentable {
    let id: UUID
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        ExtensionAnchors.set(v, for: id)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { ExtensionAnchors.set(v, for: id) }
}

// MARK: - Settings

struct ExtensionsPane: View {
    private var ext = Extensions.shared
    @State private var available: [Extensions.Available] = []
    @State private var pending: PendingInstall?
    @State private var error: String?
    @State private var importing = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 24)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) { Text("Tacet Plugins").font(.headline); BetaBadge() }
                        Text("Small additions for Tacet, checked by us, that work on every Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Tacet Plugins") { openWindow(id: "plugins") }.buttonStyle(.borderedProminent)
                }
            }
            if !Extensions.isSupported {
                Section {
                    Label("Extensions need macOS 15.4 or later.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } else {
                Section {
                    if ext.installed.isEmpty {
                        Text("No extensions yet. Add one from the apps on your Mac below, or from a file.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(ext.installed) { item in InstalledRow(item: item) }
                } header: {
                    Text("Installed")
                } footer: {
                    Text("Extensions don't run in private windows. Pages open before you add one start using it when you reload them.")
                }
                Section {
                    if available.isEmpty {
                        Text("No Safari extensions found in your apps. Install one from the Mac App Store (search for “Safari extension”), then come back here.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(available) { a in
                        HStack(spacing: 10) {
                            if let icon = a.icon { Image(nsImage: icon).resizable().frame(width: 28, height: 28) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name)
                                Text(String(format: L("From %@"), a.appName)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add…") { prepare(.appExtension(a.path)) }
                        }
                    }
                } header: {
                    Text("Safari extensions in your apps")
                } footer: {
                    Text("Many Safari extensions come with an app: ad blockers, password managers, translators and more.")
                }
                Section {
                    Button("Add from a File or Folder…") { importing = true }
                    Text("A folder with a manifest.json, or a .zip, .crx (Chrome) or .xpi (Firefox) file. Most extensions work; some features that only Chrome or Firefox have may not.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .onChange(of: ext.installed) { _, _ in refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .zip, .data], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let folder = try ext.importPackage(at: url)
                prepare(.folder(folder.path), discardOnCancel: folder)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        .sheet(item: $pending) { p in
            if #available(macOS 15.4, *) { InstallSheet(pending: p) { pending = nil } }
        }
    }

    private func refresh() {
        guard Extensions.isSupported else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Extensions.shared.findAppExtensions()
            DispatchQueue.main.async { available = found }
        }
    }

    /// Reads the extension and shows what it asks for before adding it.
    private func prepare(_ source: Extensions.Installed.Source, discardOnCancel: URL? = nil) {
        error = nil
        guard #available(macOS 15.4, *) else { return }
        Task { @MainActor in
            do {
                let e = try await ext.extensionFrom(source)
                pending = PendingInstall(extension: e, source: source, discard: discardOnCancel)
            } catch {
                if let discardOnCancel { ext.discardImported(discardOnCancel) }
                self.error = String(format: L("This extension couldn't be read: %@"), error.localizedDescription)
            }
        }
    }
}

struct PendingInstall: Identifiable {
    let id = UUID()
    let extension_: AnyObject
    let source: Extensions.Installed.Source
    let discard: URL?

    init(extension e: AnyObject, source: Extensions.Installed.Source, discard: URL?) {
        extension_ = e
        self.source = source
        self.discard = discard
    }
}

/// Shows an extension's name, description and what it asks to do, before adding it.
@available(macOS 15.4, *)
struct InstallSheet: View {
    let pending: PendingInstall
    let done: () -> Void

    private var e: WKWebExtension { pending.extension_ as! WKWebExtension }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let icon = e.icon(for: CGSize(width: 48, height: 48)) {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48)
                } else {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 32)).frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L("Add “%@”?"), e.displayName ?? L("Extension"))).font(.headline)
                    if let v = e.displayVersion ?? e.version { Text(String(format: L("Version %@"), v)).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let d = e.displayDescription, !d.isEmpty {
                Text(d).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            let asks = Extensions.summary(e)
            VStack(alignment: .leading, spacing: 6) {
                Text(asks.isEmpty ? LocalizedStringKey("It doesn't ask for any permissions.") : "It will be able to:")
                    .font(.subheadline.weight(.semibold))
                ForEach(asks, id: \.self) { line in
                    Label(line, systemImage: "checkmark.shield").font(.callout)
                }
            }
            if !e.errors.isEmpty {
                Label(String(format: L("Some parts may not work in Tacet: %@"), e.errors.map(\.localizedDescription).joined(separator: "; ")),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Only add extensions you trust: they can see and change the pages they have access to.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") {
                    if let d = pending.discard { Extensions.shared.discardImported(d) }
                    done()
                }
                .keyboardShortcut(.cancelAction)
                Button("Add Extension") {
                    Extensions.shared.install(e, source: pending.source)
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

struct InstalledRow: View {
    let item: Extensions.Installed
    private var ext = Extensions.shared
    @State private var confirmRemove = false

    init(item: Extensions.Installed) { self.item = item }

    var body: some View {
        // Redraws when the extension finishes loading.
        let _ = ext.revision
        HStack(spacing: 10) {
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if #available(macOS 15.4, *), let c = ext.context(item.id), c.optionsPageURL != nil {
                Button("Settings") {
                    if let url = c.optionsPageURL, let b = WindowRegistry.shared.lastFocused ?? WindowRegistry.shared.browsers.first { b.newTab(url: url) }
                }
            }
            Toggle("", isOn: Binding(get: { item.enabled }, set: { ext.setEnabled(item.id, $0) })).labelsHidden()
            Button { confirmRemove = true } label: { Label("Remove", systemImage: "minus.circle.fill").labelStyle(.iconOnly) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
        }
        .confirmationDialog(String(format: L("Remove “%@”?"), item.name), isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { ext.remove(item.id) }
        } message: {
            Text("Its settings and data are removed too.")
        }
    }

    @ViewBuilder private var icon: some View {
        if #available(macOS 15.4, *), let img = ext.context(item.id)?.webExtension.icon(for: CGSize(width: 28, height: 28)) {
            Image(nsImage: img).resizable()
        } else {
            Image(systemName: "puzzlepiece.extension").font(.system(size: 20)).foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        if #available(macOS 15.4, *), let c = ext.context(item.id) {
            let e = c.webExtension
            return [e.displayVersion.map { String(format: L("Version %@"), $0) }, e.displayDescription].compactMap { $0 }.joined(separator: " · ")
        }
        return item.enabled ? L("Loading…") : L("Turned off")
    }
}
