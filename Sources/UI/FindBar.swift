import SwiftUI

extension Notification.Name {
    /// ⌘G / ⇧⌘G from the menu. `object` is true when searching backwards.
    static let findAgain = Notification.Name("lumen.findAgain")
    /// ⌘E put the selected text in the find bar.
    static let findUseSelection = Notification.Name("lumen.findUseSelection")
}

struct FindBar: View {
    var tab: Tab
    @Environment(BrowserState.self) var b
    @State private var text = ""
    @State private var result = Tab.FindResult(found: true)
    @AppStorage("lumen.findCaseSensitive") private var caseSensitive = false
    @AppStorage("lumen.findWholeWord") private var wholeWord = false
    @FocusState private var focused: Bool
    /// The last text searched, for the next opening and for Use Selection for Find (⌘E).
    static var lastQuery = ""

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary).padding(.leading, 8)
            TextField("Find on page", text: $text)
                .textFieldStyle(.plain)
                .frame(width: 190)
                .focused($focused)
                .onKeyPress(keys: [.return]) { press in
                    search(backwards: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(.escape) { close(); return .handled }
                .onExitCommand { close() }
            if !text.isEmpty {
                if !result.found {
                    Text("Not found").font(.system(size: 11)).foregroundStyle(.red)
                } else if result.total > 0 {
                    Text(String(format: L("%d of %d"), result.index, result.total))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityLabel(String(format: L("Match %d of %d"), result.index, result.total))
                }
            }
            Menu {
                Toggle("Match Case", isOn: $caseSensitive)
                Toggle("Whole Words", isOn: $wholeWord)
            } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(caseSensitive || wholeWord ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .help("Find Options")
            .accessibilityLabel("Find Options")
            IconButton(systemName: "chevron.up", help: "Previous (⇧⌘G)", size: 11) { search(backwards: true) }
            IconButton(systemName: "chevron.down", help: "Next (⌘G)", size: 11) { search(backwards: false) }
            IconButton(systemName: "xmark", help: "Done", size: 11) { close() }
        }
        .frame(height: 36)
        .padding(.trailing, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .padding(10)
        .onAppear {
            text = Self.lastQuery
            DispatchQueue.main.async { focused = true }
        }
        // Typing narrows the match in place instead of jumping to the next one.
        .onChange(of: text) { _, _ in search(backwards: false, refine: true) }
        .onChange(of: caseSensitive) { _, _ in search(backwards: false, refine: true) }
        .onChange(of: wholeWord) { _, _ in search(backwards: false, refine: true) }
        .onReceive(NotificationCenter.default.publisher(for: .findAgain)) { note in
            search(backwards: note.object as? Bool ?? false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .findUseSelection)) { _ in
            if text != Self.lastQuery { text = Self.lastQuery }
        }
        .onDisappear { tab.clearFindHighlights() }
    }

    private func search(backwards: Bool, refine: Bool = false) {
        Self.lastQuery = text
        guard !text.isEmpty else { result = Tab.FindResult(found: true); tab.clearFindHighlights(); return }
        let asked = text
        tab.find(text, backwards: backwards, caseSensitive: caseSensitive, wholeWord: wholeWord, refine: refine) { r in
            // A later letter may already have started another search.
            if asked == text { result = r }
        }
    }

    private func close() {
        b.findVisible = false
        tab.clearFindHighlights()
        tab.webView?.window?.makeFirstResponder(tab.webView)
    }
}
