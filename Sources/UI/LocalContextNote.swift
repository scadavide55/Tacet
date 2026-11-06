import SwiftUI

/// Under the model picker for Ollama and LM Studio: how much the model can take, as its server runs it, and what that
/// means, so a model that's too small for a deep research isn't a surprise.
struct LocalContextNote: View {
    let provider: AIProvider
    let model: String
    private var local = LocalModels.shared

    init(provider: AIProvider, model: String) {
        self.provider = provider
        self.model = model
    }

    var body: some View {
        if let c = local.context(provider, model: model) {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Context") {
                    Text(String(format: L("%@ tokens"), c.tokens.formatted()))
                        .help(c.max.map { String(format: L("The model was trained for up to %@ tokens."), $0.formatted()) } ?? "")
                }
                Text(Self.explanation(provider, c))
                    .font(.caption).foregroundStyle(c.tokens < LocalModels.researchMinimum ? .orange : .secondary)
            }
            .onChange(of: model) { local.refresh(provider, model: model, force: true) }
        } else if provider == .lmStudio {
            Text("Load the model in LM Studio to see how much it can take.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static func explanation(_ p: AIProvider, _ c: LocalModels.Context) -> String {
        if c.tokens < LocalModels.researchMinimum {
            return p == .ollama
                ? L("Small for deep research: the assistant uses short instructions and fewer tools. Set num_ctx higher in the model's Modelfile for longer pages.")
                : L("Small for deep research: the assistant uses short instructions and fewer tools. Load the model with a longer context in LM Studio for longer pages.")
        }
        return p == .ollama
            ? L("Tacet asks Ollama for this context with each request, and fits the conversation in it.")
            : L("As loaded in LM Studio. Tacet fits the conversation in it.")
    }
}
