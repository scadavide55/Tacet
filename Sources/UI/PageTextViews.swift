import SwiftUI

/// A found passage with the matching words in bold, from the \u{2}…\u{3} marks SQLite puts around them.
func highlightedSnippet(_ snippet: String) -> Text {
    var out = Text("")
    for (i, part) in snippet.split(separator: "\u{2}", omittingEmptySubsequences: false).enumerated() {
        if i == 0 { out = out + Text(String(part)); continue }
        let pieces = part.split(separator: "\u{3}", maxSplits: 1, omittingEmptySubsequences: false)
        out = out + Text(String(pieces[0])).bold().foregroundColor(.primary)
        if pieces.count > 1 { out = out + Text(String(pieces[1])) }
    }
    return out
}

/// The same passage as plain text, for places that can't show bold.
func plainSnippet(_ snippet: String) -> String {
    snippet.replacingOccurrences(of: "\u{2}", with: "").replacingOccurrences(of: "\u{3}", with: "")
}

/// Pages found by what they said, under the history search.
struct PageTextResults: View {
    let hits: [PageText.Hit]
    let open: ([URL]) -> Void

    var body: some View {
        SwiftUI.Section {
            ForEach(hits) { hit in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Group {
                            if let icon = Favicons.shared.cached(hit.url.host) { Image(nsImage: icon).resizable() } else { Image(systemName: "doc.text").foregroundStyle(.secondary) }
                        }
                        .frame(width: 16, height: 16)
                        Text(hit.title.isEmpty ? hit.url.absoluteString : hit.title).lineLimit(1)
                        Spacer()
                        Text(hit.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                    }
                    highlightedSnippet(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .padding(.leading, 24)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open([hit.url]) }
                .contextMenu {
                    Button("Open") { open([hit.url]) }
                    Button("Forget What This Page Said") { PageText.shared.forget(urls: [hit.url]) }
                }
            }
        } header: {
            Text("In pages you've read")
        }
    }
}

/// Settings › Shield: keeping what pages said, for how long, and where never.
struct PageTextSettings: View {
    @Bindable private var s = Settings.shared
    @State private var newHost = ""
    @State private var count: Int?
    @State private var confirmForget = false

    var body: some View {
        SwiftUI.Section {
            Toggle(isOn: $s.rememberPageText) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find pages by what they said")
                    Text("Tacet keeps the text of the pages you visit on this Mac, so a search in History or the command bar finds a page by a sentence you remember. Never kept: private windows, pages with a password field and the sites below. Nothing leaves your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Keep it for", selection: $s.pageTextDays) {
                Text("1 month").tag(30)
                Text("3 months").tag(90)
                Text("1 year").tag(365)
            }
            .disabled(!s.rememberPageText)
            ForEach(s.pageTextExcluded, id: \.self) { host in
                HStack {
                    Text(host)
                    Spacer()
                    Button { s.pageTextExcluded.removeAll { $0 == host } } label: { Label("Remove", systemImage: "minus.circle.fill").labelStyle(.iconOnly) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Never keep pages from: bank.com", text: $newHost).onSubmit(addHost)
                Button("Add", action: addHost).disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Text(count.map { String(format: L("%lld pages kept"), $0) } ?? " ").foregroundStyle(.secondary)
                Spacer()
                Button("Forget All…") { confirmForget = true }.disabled(count == 0)
            }
        } header: {
            Text("Searching what pages said")
        }
        .task(id: s.rememberPageText) { count = await PageText.shared.count() }
        .confirmationDialog("Forget the text of every page?", isPresented: $confirmForget) {
            Button("Forget All", role: .destructive) {
                PageText.shared.clear()
                count = 0
            }
        } message: {
            Text("Your history stays; only what the pages said is deleted.")
        }
    }

    private func addHost() {
        var host = newHost.trimmingCharacters(in: .whitespaces).lowercased()
        if let h = URL(string: host.contains("://") ? host : "https://" + host)?.host { host = h }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard !host.isEmpty else { return }
        if !s.pageTextExcluded.contains(host) { s.pageTextExcluded.append(host) }
        PageText.shared.forget(site: host)
        newHost = ""
    }
}
