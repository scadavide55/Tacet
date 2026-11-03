import SwiftUI

/// Settings › General › Opening rules: a list of sites and where their links open.
struct OpeningRulesSettings: View {
    @Bindable private var s = Settings.shared
    private var spaces = Spaces.shared
    @State private var site = ""
    @State private var action = OpeningRule.Action.reuseTab

    private var choices: [OpeningRule.Action] {
        [.reuseTab, .privateWindow] + (s.profiles.isEmpty ? [] : [.profile(nil)] + s.profiles.map { .profile($0.id) })
            + spaces.items.map { .space($0.id) }
    }

    var body: some View {
        SwiftUI.Section {
            ForEach($s.openingRules) { $rule in
                HStack {
                    Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    Text(rule.site).fontWeight(.medium)
                    Text(OpeningRules.describe(rule.action)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { s.openingRules.removeAll { $0.id == rule.id } } label: { Label("Remove", systemImage: "minus.circle.fill").labelStyle(.iconOnly) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove this rule")
                }
            }
            HStack {
                TextField("Site, such as github.com", text: $site).onSubmit(add)
                Picker("", selection: $action) {
                    ForEach(choices, id: \.self) { Text(OpeningRules.describe($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button("Add", action: add).disabled(OpeningRule.normalizedSite(site) == nil)
            }
        } header: {
            Text("Opening rules")
        } footer: {
            Text("For links from other apps, addresses you type and links opened in a new tab. Links inside a page and sign-in windows are never moved. Right-click › Open Link in New Tab opens a link where you are, whatever the rules.")
        }
    }

    private func add() {
        guard let host = OpeningRule.normalizedSite(site) else { return }
        s.openingRules.removeAll { $0.site == host }
        s.openingRules.append(OpeningRule(site: host, action: action))
        site = ""
    }
}
