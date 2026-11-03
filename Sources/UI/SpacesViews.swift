import SwiftUI

// MARK: - Spaces in the sidebar

/// The row of Spaces at the bottom of the sidebar: one click leaves this one as it is and opens another.
struct SpaceBar: View {
    @Environment(BrowserState.self) var b
    private var spaces = Spaces.shared

    var body: some View {
        HStack(spacing: 3) {
            ForEach(spaces.items(for: b.profileID)) { space in
                SpaceButton(space: space, current: space.id == b.spaceID)
            }
            IconButton(systemName: "plus", help: spaces.items(for: b.profileID).isEmpty ? "New Space: a set of tabs to leave and come back to" : "New Space") {
                SpaceActions.askNew(in: b)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 28)
    }
}

private struct SpaceButton: View {
    let space: Space
    let current: Bool
    @Environment(BrowserState.self) var b
    @State private var hover = false

    var body: some View {
        Image(systemName: space.symbol)
            .font(.system(size: 12.5, weight: current ? .semibold : .regular))
            .foregroundStyle(current ? AnyShapeStyle(space.tint) : AnyShapeStyle(.secondary))
            .frame(width: 28, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(current ? space.tint.opacity(0.18) : Color.primary.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { b.switchSpace(to: space.id) } }
            .onHover { hover = $0 }
            .help(space.note.isEmpty ? space.name : space.name + " — " + space.note)
            .contextMenu { SpaceMenu(space: space) }
            .accessibilityLabel(space.name)
            .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }
}

/// Rename, note, icon, colour, order and delete, for one Space.
struct SpaceMenu: View {
    let space: Space
    @Environment(BrowserState.self) var b

    var body: some View {
        Button("Rename…") { SpaceActions.askRename(space, in: b) }
        Button("Edit Note…") { SpaceActions.askNote(space, in: b) }
        Menu("Icon") {
            ForEach(Space.symbols, id: \.self) { symbol in
                Button { Spaces.shared.update(space.id) { $0.symbol = symbol } } label: { Label(symbol, systemImage: symbol).labelStyle(.iconOnly) }
            }
        }
        Menu("Colour") {
            ForEach(0..<TabGroup.colors.count, id: \.self) { i in
                Button { Spaces.shared.update(space.id) { $0.color = i } } label: { Text(GroupHeader.colorNames[i]) }
            }
        }
        Divider()
        Button("Move Left") { Spaces.shared.move(space.id, by: -1) }
        Button("Move Right") { Spaces.shared.move(space.id, by: 1) }
        Divider()
        Button("Delete Space…") { SpaceActions.askDelete(space, in: b) }
        Button("Turn Off Spaces…") { SpaceActions.askTurnOff(in: b) }
    }
}

/// The Space's name and its note, at the top of the sidebar. A click on the note edits it.
struct SpaceHeader: View {
    let space: Space
    @State private var editing = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(space.name, systemImage: space.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(space.tint)
                .lineLimit(1)
            Text(space.note.isEmpty ? L("Add a note: where to pick up next time") : space.note)
                .font(.system(size: 11))
                .foregroundStyle(space.note.isEmpty ? .tertiary : .secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(space.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            note = space.note
            editing = true
        }
        .help("Click to edit this Space's note")
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Note for \(space.name)").font(.headline)
                TextField("Where to pick up next time", text: $note, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit { save() }
                HStack {
                    Spacer()
                    Button("Done") { save() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
    }

    private func save() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        Spaces.shared.update(space.id) { $0.note = text }
        editing = false
    }
}

/// With tabs along the top there's no sidebar: the current Space's icon opens a menu of all of them.
struct SpaceMenuButton: View {
    @Environment(BrowserState.self) var b
    private var spaces = Spaces.shared

    var body: some View {
        if !b.isPrivate, !spaces.items(for: b.profileID).isEmpty {
            Menu {
                ForEach(spaces.items(for: b.profileID)) { space in
                    Toggle(isOn: Binding(get: { b.spaceID == space.id }, set: { _ in b.switchSpace(to: space.id) })) {
                        Label(space.name, systemImage: space.symbol)
                    }
                }
                Divider()
                Button("New Space…") { SpaceActions.askNew(in: b) }
                if let space = b.space {
                    Button("Rename “\(space.name)”…") { SpaceActions.askRename(space, in: b) }
                    Button("Edit Note…") { SpaceActions.askNote(space, in: b) }
                    Button("Delete “\(space.name)”…") { SpaceActions.askDelete(space, in: b) }
                }
                Divider()
                Button("Turn Off Spaces…") { SpaceActions.askTurnOff(in: b) }
                Text("Each Space keeps its own tabs. Switching swaps them all.")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: b.space?.symbol ?? "square.stack")
                    if let space = b.space { Text(space.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1) }
                }
                .foregroundStyle(b.space?.tint ?? .secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(b.space.map { $0.note.isEmpty ? $0.name : $0.name + " — " + $0.note } ?? L("Spaces"))
            .accessibilityLabel(b.space.map { String(format: L("Space: %@"), $0.name) } ?? L("Spaces"))
        }
    }
}

// MARK: - Asking

enum SpaceActions {
    static func askNew(in b: BrowserState) {
        // The first time, say what happens to the tabs already open.
        let first = b.spaceID == nil && b.tabs.contains { $0.url != nil }
        let message = L("A set of tabs, groups and pinned tabs you can leave and come back to. Name it after what you do there: School, Coding, Holidays…")
            + (first ? "\n\n" + L("Your open tabs become the Space “Main”, and this window switches to the new, empty one. Switch back any time from the Space button.") : "")
        Dialogs.prompt(b.window, title: L("New Space"), message: message, defaultText: "") { name in
            guard let name else { return }
            withAnimation(.easeOut(duration: 0.15)) { b.newSpace(named: name) }
        }
    }

    static func askRename(_ space: Space, in b: BrowserState) {
        Dialogs.prompt(b.window, title: L("Rename Space"), message: "", defaultText: space.name) { name in
            guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            Spaces.shared.update(space.id) { $0.name = name }
        }
    }

    static func askNote(_ space: Space, in b: BrowserState) {
        Dialogs.prompt(b.window, title: String(format: L("Note for %@"), space.name),
                       message: L("Shown at the top of the sidebar in this Space."), defaultText: space.note) { note in
            guard let note else { return }
            Spaces.shared.update(space.id) { $0.note = note.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    static func askDelete(_ space: Space, in b: BrowserState) {
        let open = b.spaceID == space.id
        Dialogs.confirm(b.window, title: String(format: L("Delete “%@”?"), space.name),
                        message: open ? L("Its note goes with it. The tabs you see now stay open.")
                            : L("Its tabs, groups and note are deleted with it."), ok: L("Delete")) { ok in
            if ok { withAnimation(.easeOut(duration: 0.15)) { b.deleteSpace(space.id) } }
        }
    }

    static func askTurnOff(in b: BrowserState) {
        Dialogs.confirm(b.window, title: L("Turn off Spaces?"),
                        message: L("Every Space is removed. Nothing is lost: the tabs of your other Spaces come into this window, each Space as a tab group."),
                        ok: L("Turn Off")) { ok in
            if ok { withAnimation(.easeOut(duration: 0.15)) { b.turnOffSpaces() } }
        }
    }
}

/// Settings › General › Spaces: what they are, the list, and the way out.
struct SpacesSettings: View {
    private var spaces = Spaces.shared

    var body: some View {
        SwiftUI.Section {
            if spaces.items.isEmpty {
                Text("None yet. Make one with Tab › New Space… or the + at the bottom of the sidebar.").foregroundStyle(.secondary)
            }
            ForEach(spaces.items) { space in
                HStack {
                    Image(systemName: space.symbol).foregroundStyle(space.tint).frame(width: 18)
                    Text(space.name)
                    if let p = space.profile, let name = Settings.shared.profiles.first(where: { $0.id == p })?.name {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let b = window(for: space) {
                        Button("Rename…") { SpaceActions.askRename(space, in: b) }
                        Button("Delete…") { SpaceActions.askDelete(space, in: b) }
                    }
                }
            }
            if !spaces.items.isEmpty, let b = WindowRegistry.shared.lastFocused ?? WindowRegistry.shared.browsers.first(where: { !$0.isPrivate }) {
                Button("Turn Off Spaces…") { SpaceActions.askTurnOff(in: b) }
            }
        } header: {
            Text("Spaces")
        } footer: {
            Text("A Space is a set of tabs you can leave and come back to, such as School and Coding: switching swaps every tab in the window. They only appear once you make one. Turning them off keeps every tab, each Space becoming a tab group.")
        }
    }

    /// A window of the Space's profile, to act in.
    private func window(for space: Space) -> BrowserState? {
        let all = WindowRegistry.shared.browsers.filter { !$0.isPrivate && $0.profileID == space.profile }
        return all.first { $0.spaceID == space.id } ?? all.first
    }
}
