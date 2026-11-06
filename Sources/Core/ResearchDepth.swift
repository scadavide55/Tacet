import Foundation

/// How far a deep research goes: chosen from the menu on the Deep research button, and remembered.
enum ResearchDepth: String, Codable, CaseIterable, Identifiable {
    case quick, standard, deep
    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick: L("Quick")
        case .standard: L("Standard")
        case .deep: L("Thorough")
        }
    }

    var summary: String {
        switch self {
        case .quick: L("About 4 sources, in a minute or two.")
        case .standard: L("About 8 sources, checked against each other.")
        case .deep: L("About 12 sources, and a second search for what's still missing.")
        }
    }

    /// Pages read, at most.
    var sources: Int {
        switch self {
        case .quick: 4
        case .standard: 8
        case .deep: 12
        }
    }

    /// Sub-questions in the plan, at most.
    var subquestions: Int {
        switch self {
        case .quick: 3
        case .standard: 5
        case .deep: 6
        }
    }

    /// Extra rounds of searching for sub-questions with too few facts.
    var gapRounds: Int { self == .deep ? 1 : 0 }
}
