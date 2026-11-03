import AppKit
import UniformTypeIdentifiers

/// Moves Tacet's settings and Tacet Plugins to another Mac in one file. Passwords, AI keys, history, bookmarks and
/// sign-ins stay out: they have their own exports, or shouldn't travel in a plain file.
enum SettingsTransfer {
    static let fileType = UTType(filenameExtension: "tacetsettings", conformingTo: .json) ?? .json

    /// Kept on this Mac only: what's been shown once, update and filter list bookkeeping, window sizes.
    private static let local: Set<String> = ["welcomedVersion", "aiIntroduced", "aiControlExplained", "skippedVersion", "updateCheck",
                                             "filterIDs", "filterCount", "filterDate", "sidebarWidth", "assistantWidth"]

    struct PluginState: Codable {
        let id: String
        let enabled: Bool
        let pinned: Bool?
        let offSites: [String]?
    }

    struct File: Codable {
        var format = 1
        var version = UpdateChecker.currentVersion
        var date = Date()
        /// Each setting as its own JSON text, exactly as Tacet stores it.
        var settings: [String: String]
        var plugins: [PluginState]
    }

    static func make() -> Data? {
        var settings: [String: String] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("lumen.") {
            let name = String(key.dropFirst(6))
            guard !local.contains(name), let data = value as? Data, let text = String(data: data, encoding: .utf8) else { continue }
            settings[name] = text
        }
        let plugins = PluginStore.shared.installed.values.map {
            PluginState(id: $0.plugin.id, enabled: $0.enabled, pinned: $0.pinned, offSites: $0.offSites)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(File(settings: settings, plugins: plugins.sorted { $0.id < $1.id }))
    }

    static func read(_ data: Data) -> File? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(File.self, from: data)
    }

    // MARK: Export

    @MainActor
    static func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [fileType]
        panel.nameFieldStringValue = "Tacet Settings.tacetsettings"
        guard panel.runModal() == .OK, let url = panel.url, let data = make() else { return }
        do { try data.write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
    }

    // MARK: Import

    /// Reads a file, puts its plugins back from Tacet Plugins (verified as always), then its settings, and restarts
    /// Tacet so every window uses them.
    @MainActor
    static func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [fileType, .json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url), let file = read(data) else {
            if panel.url != nil {
                let alert = NSAlert()
                alert.messageText = L("This isn't a Tacet settings file.")
                alert.runModal()
            }
            return
        }
        let confirm = NSAlert()
        confirm.messageText = L("Replace your settings with the ones in this file?")
        confirm.informativeText = String(format: L("%d settings and %d plugins, from Tacet %@. Your passwords, history and bookmarks don't change. Tacet restarts to finish."),
                                         file.settings.count, file.plugins.count, file.version)
        confirm.addButton(withTitle: L("Import and Restart"))
        confirm.addButton(withTitle: L("Cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            await apply(file)
            restart()
        }
    }

    @MainActor
    static func apply(_ file: File) async {
        let store = PluginStore.shared
        if !file.plugins.isEmpty {
            await store.refresh(force: true)
            for state in file.plugins {
                if store.installed[state.id] == nil, let p = store.catalog.first(where: { $0.id == state.id }) { try? await store.install(p) }
                guard store.installed[state.id] != nil else { continue }
                store.setEnabled(state.id, state.enabled)
                store.setPinned(state.id, state.pinned ?? false)
                for site in state.offSites ?? [] { store.setOff(state.id, on: site, true) }
            }
        }
        for (name, text) in file.settings where !local.contains(name) {
            // Only well-formed values: a broken one is skipped rather than written.
            guard let data = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else { continue }
            UserDefaults.standard.set(data, forKey: "lumen." + name)
        }
        UserDefaults.standard.synchronize()
    }

    /// Quits and opens Tacet again, after the session is saved.
    @MainActor
    static func restart() {
        let path = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \(UpdateInstaller.shellQuoted(path))"]
        try? p.run()
        NSApp.terminate(nil)
    }
}
