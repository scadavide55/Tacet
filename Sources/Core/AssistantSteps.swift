import Foundation

/// One thing Tacet Assistant did while answering: thinking, a web search, a page it read, a step on a page, another
/// tool, a stage of a deep research, or a few words it wrote between steps. Steps are recorded as they really happen,
/// with their own start and end, and shown in the tidy line above the reply, which opens into the list.
struct AssistantStep: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case thinking, search, read, browse, tool, stage, note
    }

    enum Status: String, Codable {
        case running, done, failed, stopped
    }

    /// The stages a deep research goes through, as the model reports them with `research_stage`.
    enum Stage: String, Codable, CaseIterable {
        case planning, searching, reading, comparing, verifying, writing
    }

    var id = UUID()
    var kind: Kind
    /// The search query, the page's name or address, the stage's note, or the whole line for other steps.
    var detail: String
    var url: URL?
    var stage: Stage?
    var started: Date
    var ended: Date?
    var status: Status = .running
    /// What came of it, in a few words: "8 results", "Couldn't be read".
    var outcome: String?

    var running: Bool { status == .running }

    func duration(at now: Date = Date()) -> TimeInterval { max(0, (ended ?? now).timeIntervalSince(started)) }

    mutating func finish(_ status: Status = .done, outcome: String? = nil, at date: Date = Date()) {
        guard running else { return }
        self.status = status
        ended = date
        if let outcome { self.outcome = outcome }
    }

    /// What the step's row says before its detail.
    var title: String? {
        switch kind {
        case .search: running ? L("Searching the web") : L("Searched the web")
        case .read: running ? L("Reading") : L("Read")
        case .thinking: running ? L("Thinking") : String(format: L("Thought for %@"), Self.time(duration()))
        case .stage: stage.map(Self.stageTitle)
        case .browse, .tool, .note: nil
        }
    }

    static func stageTitle(_ stage: Stage) -> String {
        switch stage {
        case .planning: L("Planning the research")
        case .searching: L("Searching for sources")
        case .reading: L("Reading sources")
        case .comparing: L("Comparing sources")
        case .verifying: L("Checking the facts")
        case .writing: L("Writing the report")
        }
    }

    /// "9s", "1m 05s" or "1h 02m".
    static func time(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }
}

/// The words for the activity line: what's happening now, and a summary once it's done.
enum AssistantActivity {
    /// Thinking shorter than this isn't worth a line of its own.
    static let shortThought: TimeInterval = 2

    /// The steps worth listing: everything except a moment of thinking.
    static func listed(_ steps: [AssistantStep], now: Date = Date()) -> [AssistantStep] {
        steps.filter { $0.kind != .thinking || $0.running || $0.duration(at: now) >= shortThought }
    }

    /// Whether the line is worth showing at all.
    static func shows(_ steps: [AssistantStep], now: Date = Date()) -> Bool {
        !listed(steps, now: now).isEmpty
    }

    /// What's happening right now, or nil when nothing is running. `writing` is true while the reply streams in.
    static func live(_ steps: [AssistantStep], writing: Bool = false) -> String? {
        let running = steps.filter(\.running)
        let reads = running.filter { $0.kind == .read }.count
        if reads > 1 { return String(format: L("Reading %d pages"), reads) }
        // A tool at work leads; then thinking; then the research stage the model said it's in.
        if let step = running.last(where: { ![.thinking, .stage].contains($0.kind) }) {
            switch step.kind {
            case .search: return L("Searching the web")
            case .read: return L("Reading a page")
            case .browse: return L("Using the browser")
            default: return step.detail.isEmpty ? L("Using a tool") : step.detail
            }
        }
        let stage = running.last { $0.kind == .stage }?.stage
        if running.contains(where: { $0.kind == .thinking }) {
            if let stage, stage != .planning { return AssistantStep.stageTitle(stage) }
            // After results came back, thinking is working through them.
            let afterTools = steps.contains { [.search, .read, .browse, .tool].contains($0.kind) }
            return afterTools ? L("Going through the results") : L("Thinking")
        }
        if writing { return steps.contains { $0.kind != .thinking } ? L("Writing the answer") : nil }
        return stage.map(AssistantStep.stageTitle)
    }

    /// A summary of what was done, such as "Searched the web, read 2 pages", or nil when there was nothing to say.
    static func summary(_ steps: [AssistantStep], research: Bool = false, now: Date = Date()) -> String? {
        let count = { (k: AssistantStep.Kind) in steps.filter { $0.kind == k }.count }
        let reads = steps.filter { $0.kind == .read && $0.status == .done }.count
        if research {
            let searches = count(.search)
            guard searches + reads > 0 else { return L("Deep research") }
            return String(format: L("Researched: %d searches, %d pages read"), searches, reads)
        }
        var parts: [String] = []
        let searches = count(.search)
        if searches == 1 { parts.append(L("searched the web")) } else if searches > 1 { parts.append(String(format: L("searched the web %d times"), searches)) }
        if reads == 1 { parts.append(L("read a page")) } else if reads > 1 { parts.append(String(format: L("read %d pages"), reads)) }
        if count(.browse) > 0 { parts.append(L("used the browser")) }
        let tools = count(.tool)
        if tools == 1 { parts.append(L("used a tool")) } else if tools > 1 { parts.append(String(format: L("used %d tools"), tools)) }
        if parts.isEmpty {
            let thought = steps.filter { $0.kind == .thinking }.reduce(0) { $0 + $1.duration(at: now) }
            return thought >= shortThought ? String(format: L("Thought for %@"), AssistantStep.time(thought)) : nil
        }
        let line = parts.joined(separator: ", ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// How many steps failed, for the summary line.
    static func failures(_ steps: [AssistantStep]) -> Int { steps.filter { $0.status == .failed }.count }
}
