import SwiftUI

/// The user's own words for the assistant: who they are and how it should answer. Cut to a fixed length as they're
/// typed, so what goes with every question stays compact.
struct PersonalInstructionsSettings: View {
    @Bindable private var s = Settings.shared

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("What should Tacet Assistant know about you?")
                TextField("", text: limited($s.aiAboutMe),
                          prompt: Text("For example: I'm a teacher in Turin, I cook a lot and I'm learning Spanish."), axis: .vertical)
                    .lineLimit(2...6).textFieldStyle(.roundedBorder)
                count(s.aiAboutMe)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("How should it answer?")
                TextField("", text: limited($s.aiAnswerStyle),
                          prompt: Text("For example: In Italian, with metric units, and with sources for facts."), axis: .vertical)
                    .lineLimit(2...6).textFieldStyle(.roundedBorder)
                count(s.aiAnswerStyle)
            }
            Toggle("Use them in private windows", isOn: $s.aiInstructionsInPrivate)
        } header: {
            Text("Personal instructions")
        } footer: {
            Text("They go with every question to the provider you chose, as your own preferences. In private windows they're left out unless you turn that on.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func count(_ text: String) -> some View {
        Text(String(format: L("%d of %d characters"), text.count, AssistantPersonal.instructionLimit))
            .font(.caption).foregroundStyle(.secondary)
    }

    private func limited(_ b: Binding<String>) -> Binding<String> {
        Binding(get: { b.wrappedValue }, set: { b.wrappedValue = String($0.prefix(AssistantPersonal.instructionLimit)) })
    }
}

/// Memory, off by default: what Tacet Assistant was allowed to remember, which the user can read, change or delete.
struct MemorySettings: View {
    @Bindable private var s = Settings.shared
    private var memory = AssistantMemory.shared
    @State private var editing: UUID?
    @State private var draft = ""
    @State private var confirmDeleteAll = false

    var body: some View {
        Section {
            Toggle("Remember things between chats", isOn: $s.aiMemory)
            if memory.items.isEmpty {
                Text("Nothing remembered yet.").foregroundStyle(.secondary)
            } else {
                ForEach(memory.items) { m in row(m) }
                HStack {
                    Spacer()
                    Button("Delete All Memories…") { confirmDeleteAll = true }
                }
            }
        } header: {
            Text("Memory")
        } footer: {
            Text("When you ask, or tell it something lasting about yourself, Tacet Assistant can remember a short fact for later chats. It asks you before saving each one. Memories are kept on this Mac only, are included in your encrypted backup, and are never used or saved in private windows. Like your instructions, they go with your questions to the provider you chose.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Delete all memories?", isPresented: $confirmDeleteAll) {
            Button("Delete All", role: .destructive) { memory.deleteAll(); editing = nil }
        } message: {
            Text("Tacet Assistant will forget everything it remembered. This can't be undone.")
        }
    }

    @ViewBuilder
    private func row(_ m: AssistantMemory.Memory) -> some View {
        if editing == m.id {
            HStack {
                TextField("", text: $draft, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder)
                    .onSubmit { save(m) }
                Button("Done") { save(m) }
                Button("Cancel") { editing = nil }
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(m.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button { draft = m.text; editing = m.id } label: { Label("Edit", systemImage: "pencil").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help("Edit")
                Button { memory.delete(m.id) } label: { Label("Delete", systemImage: "trash").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help("Delete")
            }
        }
    }

    private func save(_ m: AssistantMemory.Memory) {
        memory.update(m.id, text: draft)
        editing = nil
    }
}
