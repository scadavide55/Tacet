import SwiftUI

/// The panes of Settings, for the search field to switch to.
enum SettingsPane: String, CaseIterable {
    case general, appearance, shield, passwords, search, sites, ai, automations, extensions, advanced

    var title: String {
        ["general": "General", "appearance": "Appearance", "shield": "Shield", "passwords": "Passwords", "search": "Search",
         "sites": "Sites", "ai": "AI", "automations": "Automations", "extensions": "Extensions", "advanced": "Advanced"][rawValue]!
    }
}

/// Finding a setting by name. The list holds the label of every toggle, picker and section in the panes; a test checks
/// that a new toggle in a pane is listed here too.
enum SettingsSearch {
    static let entries: [(title: String, pane: SettingsPane)] = [
        ("Updates", .general),
        ("Check for updates automatically", .general),
        ("Language", .general),
        ("Tabs", .general),
        ("Restore windows and tabs when Tacet opens", .general),
        ("Open the command bar on every new tab", .general),
        ("Show a preview with memory use when you hover over a tab", .general),
        ("Pinned tabs open links to other sites in new tabs", .general),
        ("Organize tabs", .general),
        ("Group when a site has", .general),
        ("Open pages in tabs instead of windows", .general),
        ("Automatically close tabs", .general),
        ("Block videos that play sound automatically", .general),
        ("Open new tabs", .general),
        ("Hibernate background tabs", .general),
        ("Start page", .general),
        ("Show clock", .general),
        ("Show greeting", .general),
        ("Show favorites", .general),
        ("Downloads", .general),
        ("Ask where to save each download", .general),
        ("Remove from the downloads list", .general),
        ("Theme", .appearance),
        ("Appearance", .appearance),
        ("Accent colour", .appearance),
        ("Window style", .appearance),
        ("App icon", .appearance),
        ("Tabs", .appearance),
        ("Show colour in tab bar", .appearance),
        ("Always show website titles in tabs", .appearance),
        ("Sidebar position", .appearance),
        ("Put the address bar in the sidebar", .appearance),
        ("Sidebar width", .appearance),
        ("Compact tabs", .appearance),
        ("Page", .appearance),
        ("Float the page with rounded corners", .appearance),
        ("Corner radius", .appearance),
        ("Show the full address", .appearance),
        ("Show link addresses on hover", .appearance),
        ("Scroll up at the top of a page to reload it", .appearance),
        ("Start page background", .appearance),
        ("Hide cookie consent banners", .shield),
        ("Skip YouTube ads", .shield),
        ("EasyList (ads)", .shield),
        ("EasyPrivacy (trackers)", .shield),
        ("AdGuard Base (ads, another list)", .shield),
        ("Fanboy Annoyances (pop-ups, social widgets, newsletters)", .shield),
        ("Privacy", .shield),
        ("Block third-party cookies", .shield),
        ("Remove tracking parameters from links", .shield),
        ("Upgrade connections to HTTPS", .shield),
        ("Confirm before downloading apps, installers and scripts", .shield),
        ("Lock private windows with Touch ID when Tacet is in the background", .shield),
        ("Tell sites not to sell or share my data (Global Privacy Control)", .shield),
        ("Clear cookies, cache and history when Tacet quits", .shield),
        ("Sites where Shield is off", .shield),
        ("Search engine", .search),
        ("Search with", .search),
        ("Show search suggestions", .search),
        ("Complete addresses of sites you visit often", .search),
        ("Force dark pages (experimental)", .sites),
        ("Default zoom", .sites),
        ("Camera and microphone", .sites),
        ("Zoom levels", .sites),
        ("Web content", .advanced),
        ("Enable JavaScript", .advanced),
        ("User agent", .advanced),
        ("Developer Mode", .advanced),
        ("Data", .advanced),
        ("Data folder", .advanced),
        ("Version", .advanced),
        ("Password manager", .passwords),
        ("Offer to save passwords", .passwords),
        ("Suggest saved passwords on sign-in pages", .passwords),
        ("Never save passwords for", .passwords),
        ("Provider", .ai),
        ("Server address", .ai),
        ("Default model", .ai),
        ("This model can read images", .ai),
        ("Length", .ai),
        ("Personality", .ai),
        ("Web access: search the web and read pages", .ai),
        ("Privacy", .ai),
        ("Shortcut", .automations),
        ("Steps", .automations),
        ("Profiles", .general), ("Spaces", .general), ("Web apps", .general), ("Default browser", .general),
        ("Import from another browser", .general), ("Tacet Shield", .shield),
        ("Customized sites", .sites), ("Tacet Assistant", .ai), ("Extensions", .extensions),
    ]

    /// Settings whose name, in English or in the language Tacet is shown in, has every word typed.
    static func matches(_ query: String) -> [(title: String, pane: SettingsPane)] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.filter { e in
            let hay = (e.title + " " + L(e.title) + " " + e.pane.title + " " + L(e.pane.title)).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }
}

/// What the search field in Settings found, over the pane; choosing one opens its pane.
struct SettingsSearchResults: View {
    let query: String
    let pick: (SettingsPane) -> Void

    var body: some View {
        let found = SettingsSearch.matches(query)
        Group {
            if found.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(found.indices, id: \.self) { i in
                    Button { pick(found[i].pane) } label: {
                        HStack {
                            Text(L(found[i].title))
                            Spacer()
                            Text(L(found[i].pane.title)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
