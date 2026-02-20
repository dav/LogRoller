import Foundation
import Testing
@testable import LogRollerCore

@Suite
struct NDJSONEventStoreTests {
    @Test
    func ingestWritesNDJSONAndUpdatesRunIndex() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let store = try NDJSONEventStore(rootDirectory: root)
        let batch = IngestBatchPayload(
            runID: "run_test",
            deviceID: "device_a",
            events: [
                IncomingEvent(
                    ts: .now,
                    level: .error,
                    event: "rtc.failed",
                    seq: 1,
                    payload: .object(["reason": .string("timeout")])
                )
            ]
        )

        let receipt = try await store.ingest(batch: batch, receiveDate: .now)
        #expect(receipt.ok)
        #expect(receipt.stored == 1)
        #expect(receipt.runID == "run_test")
        #expect(receipt.deviceID == "device_a")

        let runs = await store.listRuns(limit: 10)
        #expect(runs.count == 1)
        #expect(runs.first?.eventCount == 1)
        #expect(runs.first?.errorCount == 1)

        let events = try await store.events(runID: "run_test", deviceID: "device_a", limit: 10)
        #expect(events.count == 1)
        #expect(events.first?.event == "rtc.failed")

        let fileURL = root
            .appending(path: "run_test", directoryHint: .isDirectory)
            .appending(path: "device_a.ndjson")
        #expect(FileManager.default.fileExists(atPath: fileURL.path()))
    }

    @Test
    func loadsLegacyCamelCaseRowsFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runDirectory = root.appending(path: "run_manual", directoryHint: .isDirectory)
        let fileURL = runDirectory.appending(path: "mac_preview.ndjson")

        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let legacyLine = """
        {"id":"11111111-1111-1111-1111-111111111111","runID":"run_manual","deviceID":"mac_preview","ts":"2026-02-18T22:00:00.000Z","recvTS":"2026-02-18T22:00:00.100Z","level":"info","event":"ui.simulated","seq":7,"payload":{"source":"desktop"}}
        """
        try Data((legacyLine + "\n").utf8).write(to: fileURL)

        let store = try NDJSONEventStore(rootDirectory: root)
        let runs = await store.listRuns(limit: 10)
        #expect(runs.count == 1)
        #expect(runs.first?.runID == "run_manual")
        #expect(runs.first?.eventCount == 1)

        let events = try await store.events(runID: "run_manual", deviceID: nil, limit: 10)
        #expect(events.count == 1)
        #expect(events.first?.deviceID == "mac_preview")
        #expect(events.first?.event == "ui.simulated")
    }

    @Test
    func loadsLegacyDoubleUnderscoreKeysFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runDirectory = root.appending(path: "run_manual", directoryHint: .isDirectory)
        let fileURL = runDirectory.appending(path: "mac_preview.ndjson")

        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let legacyLine = """
        {"id":"22222222-2222-2222-2222-222222222222","run__id":"run_manual","device__id":"mac_preview","ts":"2026-02-18T22:00:00.000Z","recv__ts":"2026-02-18T22:00:00.100Z","level":"info","event":"ui.simulated","seq":8,"payload":{"source":"desktop"}}
        """
        try Data((legacyLine + "\n").utf8).write(to: fileURL)

        let store = try NDJSONEventStore(rootDirectory: root)
        let runs = await store.listRuns(limit: 10)
        #expect(runs.count == 1)
        #expect(runs.first?.runID == "run_manual")
        #expect(runs.first?.eventCount == 1)

        let events = try await store.events(runID: "run_manual", deviceID: nil, limit: 10)
        #expect(events.count == 1)
        #expect(events.first?.deviceID == "mac_preview")
        #expect(events.first?.event == "ui.simulated")
    }

    @Test
    func loadsLegacyHyphenKeysFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runDirectory = root.appending(path: "run_manual", directoryHint: .isDirectory)
        let fileURL = runDirectory.appending(path: "mac_preview.ndjson")

        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let legacyLine = """
        {"id":"33333333-3333-3333-3333-333333333333","run-id":"run_manual","device-id":"mac_preview","ts":"2026-02-18T22:00:00.000Z","recv-ts":"2026-02-18T22:00:00.100Z","level":"info","event":"ui.simulated","seq":"9","payload":{"source":"desktop"}}
        """
        try Data((legacyLine + "\n").utf8).write(to: fileURL)

        let store = try NDJSONEventStore(rootDirectory: root)
        let events = try await store.events(runID: "run_manual", deviceID: nil, limit: 10)
        #expect(events.count == 1)
        #expect(events.first?.deviceID == "mac_preview")
        #expect(events.first?.event == "ui.simulated")
        #expect(events.first?.seq == 9)
    }

    @Test
    func returnsFallbackEventForUnparseableRow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runDirectory = root.appending(path: "run_manual", directoryHint: .isDirectory)
        let fileURL = runDirectory.appending(path: "mac_preview.ndjson")

        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let malformedLine = "not_json_at_all"
        try Data((malformedLine + "\n").utf8).write(to: fileURL)

        let store = try NDJSONEventStore(rootDirectory: root)
        let events = try await store.events(runID: "run_manual", deviceID: nil, limit: 10)
        #expect(events.count == 1)
        #expect(events.first?.runID == "run_manual")
        #expect(events.first?.deviceID == "mac_preview")
        #expect(events.first?.event == "storage.unparsed_row")
    }

    @Test
    func deleteRunRemovesDataFromDiskAndIndex() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let store = try NDJSONEventStore(rootDirectory: root)
        let batch = IngestBatchPayload(
            runID: "run_delete_me",
            deviceID: "device_a",
            events: [
                IncomingEvent(
                    ts: .now,
                    level: .info,
                    event: "delete.test",
                    seq: 1,
                    payload: .object(["source": .string("test")])
                )
            ]
        )

        _ = try await store.ingest(batch: batch, receiveDate: .now)
        #expect((await store.listRuns(limit: 10)).contains(where: { $0.runID == "run_delete_me" }))

        try await store.deleteRun(runID: "run_delete_me")

        let runs = await store.listRuns(limit: 10)
        #expect(!runs.contains(where: { $0.runID == "run_delete_me" }))

        let deletedRunDirectory = root.appending(path: "run_delete_me", directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: deletedRunDirectory.path(percentEncoded: false)))

        let events = try await store.events(runID: "run_delete_me", deviceID: nil, limit: 10)
        #expect(events.isEmpty)
    }
}
