import SwiftUI

/// Settings › Automations: lists of steps you make once and run with a click or a shortcut.
struct AutomationsPane: View {
    @Bindable private var s = Settings.shared
    @State private var selected: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(s.automations) { a in
                        HStack {
                            Text(a.name).lineLimit(1)
                            Spacer()
                            if let k = a.shortcutLabel { Text(k).font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(a.id)
                    }
                }
                .overlay {
                    if s.automations.isEmpty {
                        Text("Steps Tacet runs in order, the same way every time. Start from + or an example.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    Button { add(Automation(name: L("New Automation"))) } label: { Label("New automation", systemImage: "plus").labelStyle(.iconOnly) }.help("New automation")
                    Button { remove() } label: { Label("Delete automation", systemImage: "minus").labelStyle(.iconOnly) }.disabled(selected == nil).help("Delete automation")
                    Spacer()
                    Menu("Examples") {
                        ForEach(Automation.examples) { ex in Button(ex.name) { add(Automation(name: ex.name, steps: ex.steps)) } }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 200)
            Divider()
            if let id = selected, s.automations.contains(where: { $0.id == id }) {
                // Bound by id, not by position: a deleted automation must not leave the editor reading a gone index.
                AutomationEditor(automation: Binding(
                    get: { s.automations.first { $0.id == id } ?? Automation(id: id, name: "") },
                    set: { new in if let j = s.automations.firstIndex(where: { $0.id == id }) { s.automations[j] = new } }))
                    .id(id)
            } else {
                Text("Choose an automation, or make one with +.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func add(_ a: Automation) {
        s.automations.append(a)
        selected = a.id
    }

    private func remove() {
        s.automations.removeAll { $0.id == selected }
        selected = s.automations.first?.id
    }
}

private struct AutomationEditor: View {
    @Binding var automation: Automation
    private var spaces = Spaces.shared
    @Bindable private var s = Settings.shared

    init(automation: Binding<Automation>) { _automation = automation }

    var body: some View {
        Form {
            TextField("Name", text: $automation.name)
            Picker("Shortcut", selection: $automation.shortcut) {
                Text("None").tag(Int?.none)
                ForEach(1...9, id: \.self) { n in
                    let taken = s.automations.contains { $0.id != automation.id && $0.shortcut == n }
                    Text("⌃⌥⌘\(n)" + (taken ? " — " + L("in use") : "")).tag(Int?.some(n))
                }
            }
            SwiftUI.Section("Steps") {
                ForEach(Array(automation.steps.enumerated()), id: \.offset) { i, step in
                    HStack {
                        Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(step.label).lineLimit(1)
                        Spacer()
                        Button { move(i, -1) } label: { Label("Move Up", systemImage: "chevron.up").labelStyle(.iconOnly) }.disabled(i == 0)
                        Button { move(i, 1) } label: { Label("Move Down", systemImage: "chevron.down").labelStyle(.iconOnly) }.disabled(i == automation.steps.count - 1)
                        Button { if automation.steps.indices.contains(i) { automation.steps.remove(at: i) } } label: { Label("Remove", systemImage: "minus.circle.fill").labelStyle(.iconOnly) }.foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                Menu("Add Step") {
                    Button("Open a Page in a New Tab…") { askURL { automation.steps.append(.openTab($0)) } }
                    Button("Open a Page in This Tab…") { askURL { automation.steps.append(.openHere($0)) } }
                    Button("Show a Page Beside This One…") { askURL { automation.steps.append(.openSplit($0)) } }
                    if !spaces.items.isEmpty {
                        Menu("Switch to a Space") {
                            ForEach(spaces.items) { sp in Button(sp.name) { automation.steps.append(.openSpace(sp.id)) } }
                        }
                    }
                    Divider()
                    Button(Automation.Step.copyMarkdown.label) { automation.steps.append(.copyMarkdown) }
                    Button(Automation.Step.groupSelectedLinks.label) { automation.steps.append(.groupSelectedLinks) }
                    Button(Automation.Step.reader.label) { automation.steps.append(.reader) }
                    Button(Automation.Step.focusMode.label) { automation.steps.append(.focusMode) }
                    Button(Automation.Step.closeOtherTabs.label) { automation.steps.append(.closeOtherTabs) }
                    Button(Automation.Step.hibernateOthers.label) { automation.steps.append(.hibernateOthers) }
                    Menu("Appearance") {
                        ForEach(["dark", "light", "system"], id: \.self) { a in
                            Button(Automation.Step.appearance(a).label) { automation.steps.append(.appearance(a)) }
                        }
                    }
                }
            }
            SwiftUI.Section {
                Button("Run Now") {
                    guard let b = WindowRegistry.shared.lastFocused ?? WindowRegistry.shared.browsers.first else { return }
                    let a = automation
                    Task { @MainActor in await AutomationRunner.run(a, in: b) }
                }
                .disabled(automation.steps.isEmpty)
            } footer: {
                Text("Also in the command bar (type its name) and in Tab › Automations.")
            }
        }
        .formStyle(.grouped)
    }

    private func move(_ i: Int, _ by: Int) {
        let j = i + by
        guard automation.steps.indices.contains(i), automation.steps.indices.contains(j) else { return }
        automation.steps.swapAt(i, j)
    }

    private func askURL(_ done: @escaping (URL) -> Void) {
        Dialogs.prompt(nil, title: L("Which page?"), message: L("An address, such as github.com/notifications."), defaultText: "") { text in
            guard let text, let url = InputResolver.resolve(text) else { return }
            done(url)
        }
    }
}
