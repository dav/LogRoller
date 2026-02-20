import Foundation

public protocol EventStore: Sendable {
    func ingest(batch: IngestBatchPayload, receiveDate: Date) async throws -> IngestReceipt
    func listRuns(limit: Int) async -> [RunSummary]
    func listDevices(runID: String) async -> [DeviceSummary]
    func events(runID: String, deviceID: String?, limit: Int) async throws -> [StoredEvent]
    func deleteRun(runID: String) async throws
}
