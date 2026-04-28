import Foundation

public enum RunSummaryFilter {
    public static func filtered(_ runSummaries: [RunSummary], matching query: String) -> [RunSummary] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return runSummaries
        }

        return runSummaries.filter { runSummary in
            runSummary.runID.localizedStandardContains(trimmedQuery)
        }
    }
}
