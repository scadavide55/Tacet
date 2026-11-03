import SwiftUI

/// The window of an installed web app: just the site, with a slim title bar.
struct WebAppLayout: View {
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared

    var body: some View {
        ZStack {
            ChromeBackground()
            VStack(spacing: 0) {
                if let tab = b.current { WebAppBar(tab: tab) }
                if let tab = b.current { TabPane(tab: tab, isSplit: false).id(tab.id) }
            }
            if b.paletteVisible { CommandPalette() }
        }
    }
}

private struct WebAppBar: View {
    var tab: Tab

    var body: some View {
        ZStack {
            HStack(spacing: 2) {
                Spacer().frame(width: 72)
                NavButtons(tab: tab)
                Spacer()
                IconButton(systemName: "safari", help: "Open in Tacet") {
                    if let u = tab.url { WebApp.openInBrowser(u) }
                }
            }
            HStack(spacing: 6) {
                FaviconView(tab: tab, size: 14)
                Text(tab.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            }
            .frame(maxWidth: 420)
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            if tab.isLoading { LoadingLine(load: tab.load) }
        }
    }
}

/// "Install as App": name, icon and start page of the site, then builds the app.
struct InstallAppSheet: View {
    var tab: Tab
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: WebApp.Candidate?
    @State private var name = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Install as App").font(.title2.weight(.bold))
            if let c = candidate {
                Group {
                    if let icon = c.icon {
                        Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(12)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    } else {
                        Image(systemName: "app.dashed").resizable().aspectRatio(contentMode: .fit).padding(18).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                TextField("App name", text: $name).textFieldStyle(.roundedBorder).frame(width: 280).multilineTextAlignment(.center)
                Text(c.startURL.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 360)
                Text("The app gets its own window and Dock icon, and opens in ~/Applications/Tacet Apps. Sign in once inside the app: it keeps its own cookies.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Install") { install(c) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    if working { ProgressView().controlSize(.small) }
                }
            } else {
                ProgressView().padding(40)
            }
        }
        .padding(26)
        .frame(width: 440)
        .onAppear {
            WebApp.candidate(for: tab) { c in
                candidate = c
                name = c.name
            }
        }
    }

    private func install(_ c: WebApp.Candidate) {
        var c = c
        c.name = name
        working = true
        WebApp.install(c) { result in
            working = false
            switch result {
            case .success: dismiss()
            case .failure(let e): error = e.localizedDescription
            }
        }
    }
}

/// Installed web apps, for Settings.
struct WebAppsSection: View {
    @State private var apps = WebApp.installed()

    var body: some View {
        Section {
            if apps.isEmpty {
                Text("No web apps yet. Open a site and choose Install as App from the page menu.").foregroundStyle(.secondary)
            }
            ForEach(apps) { app in
                HStack {
                    Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                        Text(app.site).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Open") { NSWorkspace.shared.openApplication(at: app.url, configuration: .init()) }
                    Button { WebApp.remove(app) { apps = WebApp.installed() } } label: { Label("Delete", systemImage: "trash").labelStyle(.iconOnly) }
                        .buttonStyle(.borderless).help(L("Move to Trash"))
                }
            }
        } header: {
            Text("Web Apps")
        }
        .onAppear { apps = WebApp.installed() }
    }
}
