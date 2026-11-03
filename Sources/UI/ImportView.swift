import SwiftUI

/// Imports bookmarks, history and sign-ins from the browsers found on this Mac.
struct ImportView: View {
    @State private var sources: [BrowserSource] = []
    @State private var selected: BrowserSource.ID?
    @State private var profileID: BrowserProfile.ID?
    @State private var options = ImportOptions()
    @State private var working = false
    @State private var result: ImportResult?
    @State private var resultSource = ""

    private var source: BrowserSource? { sources.first { $0.id == selected } }
    private var profile: BrowserProfile? {
        source.flatMap { s in s.profiles.first { $0.id == profileID } ?? s.profiles.first }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import from Another Browser").font(.title2.weight(.semibold))
                Text("Bring your bookmarks, history and sign-ins into Tacet. Nothing leaves your Mac.")
                    .foregroundStyle(.secondary)
            }

            if sources.isEmpty {
                ContentUnavailableView("No Other Browsers Found", systemImage: "safari",
                                       description: Text("Tacet looks for Safari, Firefox and Chromium browsers such as Chrome, Opera, Brave, Edge and Arc."))
                    .frame(maxHeight: .infinity)
            } else {
                List(sources, selection: $selected) { s in
                    HStack(spacing: 10) {
                        Group {
                            if let icon = s.icon { Image(nsImage: icon).resizable() } else { Image(systemName: "globe").resizable().foregroundStyle(.secondary) }
                        }
                        .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).font(.system(size: 13, weight: .medium))
                            Text(s.profiles.count == 1 ? LocalizedStringKey("1 profile") : "\(s.profiles.count) profiles")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(s.id)
                }
                .frame(height: 190)
                .onChange(of: selected) { _, _ in profileID = nil; result = nil }

                if let source {
                    Form {
                        if source.profiles.count > 1 {
                            Picker("Profile", selection: Binding(get: { profile?.id }, set: { profileID = $0 })) {
                                ForEach(source.profiles) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                        Toggle("Bookmarks", isOn: $options.bookmarks)
                        Toggle("History", isOn: $options.history)
                        Toggle(isOn: $options.cookies) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sign-ins (cookies)")
                                Text(cookieNote(source)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if isArc {
                            Toggle(isOn: $options.arcSidebar) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Spaces and pinned tabs")
                                    Text("Favorites become pinned tabs, each Space and folder a tab group in the front window. They load only when you open them.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Toggle("Also today's unpinned tabs", isOn: $options.arcToday).disabled(!options.arcSidebar)
                        }
                    }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                    .frame(height: (source.profiles.count > 1 ? 210 : 170) + (isArc ? 110 : 0))
                }
            }

            if let result { ResultView(result: result, source: resultSource) }

            Text("Passwords aren't imported directly, because other browsers keep them encrypted. Export them from your old browser as a CSV file, then use Import from CSV in Settings › Passwords.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Refresh") { detect() }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Import") { runImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || profile == nil || !(options.bookmarks || options.history || options.cookies || (isArc && options.arcSidebar)))
            }
        }
        .padding(20)
        .frame(width: 500)
        .frame(minHeight: 560)
        .tint(Settings.shared.accent)
        .onAppear(perform: detect)
    }

    private var isArc: Bool { source?.bundleID == ArcImport.bundleID }

    private func cookieNote(_ s: BrowserSource) -> String {
        switch s.kind {
        case .chromium: String(format: L("Keeps you signed in to sites. macOS will ask you to allow access to “%@” in your Keychain: choose Allow."), s.keychainService ?? "")
        case .safari: L("Keeps you signed in to sites. Needs Full Disk Access for Tacet.")
        case .firefox: L("Keeps you signed in to sites.")
        }
    }

    private func detect() {
        sources = BrowserImporter.detect()
        if source == nil { selected = sources.first?.id }
    }

    private func runImport() {
        guard let source, let profile else { return }
        working = true
        result = nil
        BrowserImporter.run(source, profile: profile, options: options) { r in
            working = false
            resultSource = source.name
            result = r
        }
    }
}

private struct ResultView: View {
    let result: ImportResult
    let source: String

    /// App Translocation (a quarantined download opened where it was) or a mounted disk image.
    static var runningFromTemporaryCopy: Bool {
        let path = Bundle.main.bundleURL.path
        return path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.warnings.isEmpty || result.imported > 0 {
                Label(String(format: L("Imported from %@: %@."), source, result.summary), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            ForEach(result.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if result.needsFullDiskAccess {
                Button("Open Full Disk Access Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                Text("Turn on Tacet in the list. When you come back to Tacet, the import finishes by itself.").font(.caption).foregroundStyle(.secondary)
                // A copy macOS runs from a temporary place (a downloaded app it moved aside, or the disk image) never
                // gets the permission given to the one in Applications.
                if Self.runningFromTemporaryCopy {
                    Text("Tacet is running from a temporary copy, so the permission can't reach it. Quit Tacet, drag it into the Applications folder, open it from there, then turn it on in the list.")
                        .font(.caption).foregroundStyle(.orange)
                }
                // macOS ties the permission to the copy of Tacet it was given to, so an older copy in the list can be
                // switched on while this one is still blocked.
                Text(String(format: L("Already on? macOS may have given it to an older copy of Tacet. Select Tacet in the list, remove it with −, then press + and choose %@."),
                            Bundle.main.bundleURL.path))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Show This Tacet in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
