import XCTest
import LogRollerCore

final class RunSummaryFilterTests: XCTestCase {
    func testFilteringMatchesRunIDsCaseInsensitively() {
        let runSummaries = [
            makeRunSummary(runID: "run_ABC_001"),
            makeRunSummary(runID: "run_DEF_002"),
            makeRunSummary(runID: "nightly_abc_003")
        ]

        let filtered = RunSummaryFilter.filtered(runSummaries, matching: "abc")

        XCTAssertEqual(filtered.map(\.runID), ["run_ABC_001", "nightly_abc_003"])
    }

    func testFilteringIgnoresWhitespaceOnlyQuery() {
        let runSummaries = [
            makeRunSummary(runID: "run_001"),
            makeRunSummary(runID: "run_002")
        ]

        let filtered = RunSummaryFilter.filtered(runSummaries, matching: "  ")

        XCTAssertEqual(filtered, runSummaries)
    }

    private func makeRunSummary(runID: String) -> RunSummary {
        RunSummary(
            runID: runID,
            createdAt: .now,
            updatedAt: .now,
            deviceCount: 1,
            eventCount: 10,
            errorCount: 0
        )
    }
}
