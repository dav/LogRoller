import Foundation
import Observation
import LogRollerCore
import LogRollerServer

@MainActor
@Observable
final class AppModel {
    private static let skipCloseWarningKey = "skip_close_warning"
    private static let refreshInterval: Duration = .seconds(2)

    private let store: NDJSONEventStore
    private let serverController: InProcessServerController

    var configuredPort: UInt16 = 8443
    var serverStatus: ServerStatus = .init(state: .stopped)
    var runSummaries: [RunSummary] = []
    var deviceSummaries: [DeviceSummary] = []
    var selectedRunID: String?
    var selectedDeviceID: String?
    var selectedEvents: [StoredEvent] = []
    var skipCloseWarning: Bool = UserDefaults.standard.bool(forKey: AppModel.skipCloseWarningKey) {
        didSet {
            UserDefaults.standard.set(skipCloseWarning, forKey: AppModel.skipCloseWarningKey)
        }
    }
    var lastErrorMessage: String?
    var ingestBaseURLs: [String] {
        guard serverStatus.isRunning, let port = serverStatus.port else {
            return []
        }
        return LogRollerNetwork.ingestBaseURLs(port: port)
    }
    var primaryIngestBaseURL: String? {
        ingestBaseURLs.first
    }

    private var didStart = false
    private var refreshTask: Task<Void, Never>?

    init() {
        let (eventStore, storeWarning) = Self.makeStore()
        store = eventStore
        serverController = InProcessServerController(router: LogRollerRouter(store: eventStore))
        lastErrorMessage = storeWarning
    }

    func startIfNeeded() async {
        guard !didStart else {
            return
        }

        didStart = true
        debugLog("startIfNeeded: initializing app model")
        let storageRootPath = await store.storageRootPath()
        debugLog("storage root: \(storageRootPath)")
        if let lastErrorMessage {
            debugLog("startup warning: \(lastErrorMessage)")
        }
        await startServer()
        await refreshRuns()
        startRefreshLoopIfNeeded()
    }

    func startServer() async {
        await serverController.start(port: configuredPort)
        await refreshStatus()
        if !serverStatus.isRunning, let startError = await serverController.currentStartError() {
            lastErrorMessage = "Server failed to start: \(startError)"
        }
        debugLog("startServer: status=\(serverStatus.state.rawValue), port=\(serverStatus.port.map(String.init) ?? "nil")")
    }

    func stopServer() async {
        await serverController.stop()
        await refreshStatus()
        debugLog("stopServer: status=\(serverStatus.state.rawValue)")
    }

    func refreshStatus() async {
        serverStatus = await serverController.currentStatus()
    }

    func refreshRuns() async {
        runSummaries = await store.listRuns(limit: 200)
        debugLog("refreshRuns: fetched \(runSummaries.count) runs")

        if selectedRunID == nil {
            selectedRunID = runSummaries.first?.runID
            debugLog("refreshRuns: auto-selected run \(selectedRunID ?? "nil")")
        }

        if let selectedRunID, runSummaries.contains(where: { $0.runID == selectedRunID }) {
            await refreshDevicesAndEvents()
        } else {
            selectedRunID = nil
            selectedDeviceID = nil
            deviceSummaries = []
            selectedEvents = []
            debugLog("refreshRuns: cleared selection because selected run is missing")
        }
    }

    func setSelectedRun(_ runID: String?) async {
        selectedRunID = runID
        selectedDeviceID = nil
        debugLog("setSelectedRun: run=\(runID ?? "nil"), device reset to all")
        await refreshDevicesAndEvents()
    }

    func setSelectedDevice(_ deviceID: String?) async {
        selectedDeviceID = deviceID
        debugLog("setSelectedDevice: device=\(deviceID ?? "all")")
        await refreshEvents()
    }

    func simulateIngest() async {
        let event = IncomingEvent(
            ts: .now,
            level: .info,
            event: "ui.simulated",
            runID: selectedRunID,
            deviceID: selectedDeviceID,
            seq: Int.random(in: 1...10_000),
            payload: .object(["source": .string("desktop")])
        )

        let batch = IngestBatchPayload(
            runID: selectedRunID ?? "run_manual",
            deviceID: selectedDeviceID ?? "mac_preview",
            events: [event]
        )

        do {
            let body = try LogRollerJSONCoders.encoder.encode(batch)
            let request = HTTPRequest(method: "POST", path: "/ingest", headers: ["Content-Type": "application/json"], body: body)
            let response = await serverController.handle(request)

            guard response.statusCode == 200 else {
                lastErrorMessage = "Simulated ingest failed with HTTP \(response.statusCode)."
                return
            }

            let receipt = try LogRollerJSONCoders.decoder.decode(IngestReceipt.self, from: response.body)
            selectedRunID = receipt.runID
            selectedDeviceID = nil
            lastErrorMessage = nil
            debugLog("simulateIngest: receipt stored=\(receipt.stored), run=\(receipt.runID), device=\(receipt.deviceID)")
            await refreshRuns()
        } catch {
            lastErrorMessage = "Simulated ingest failed: \(error.localizedDescription)"
            debugLog("simulateIngest: failed with error: \(error.localizedDescription)")
        }
    }

    func deleteRun(_ runID: String) async {
        do {
            try await store.deleteRun(runID: runID)

            if selectedRunID == runID {
                selectedRunID = nil
                selectedDeviceID = nil
                selectedEvents = []
                deviceSummaries = []
            }

            lastErrorMessage = nil
            debugLog("deleteRun: removed run \(runID)")
            await refreshRuns()
        } catch {
            lastErrorMessage = "Unable to delete run \(runID): \(error.localizedDescription)"
            debugLog("deleteRun: failed for run \(runID): \(error.localizedDescription)")
        }
    }

    private func refreshDevicesAndEvents() async {
        guard let selectedRunID else {
            deviceSummaries = []
            selectedEvents = []
            debugLog("refreshDevicesAndEvents: no selected run")
            return
        }

        deviceSummaries = await store.listDevices(runID: selectedRunID)
        debugLog("refreshDevicesAndEvents: run=\(selectedRunID), devices=\(deviceSummaries.count), selectedDevice=\(selectedDeviceID ?? "all")")

        if let selectedDeviceID, deviceSummaries.contains(where: { $0.deviceID == selectedDeviceID }) {
            await refreshEvents()
        } else {
            selectedDeviceID = nil
            await refreshEvents()
        }
    }

    private func refreshEvents() async {
        guard let selectedRunID else {
            selectedEvents = []
            debugLog("refreshEvents: no selected run")
            return
        }

        do {
            debugLog("refreshEvents: loading run=\(selectedRunID), device=\(selectedDeviceID ?? "all")")
            selectedEvents = try await store.events(runID: selectedRunID, deviceID: selectedDeviceID, limit: 500)
            lastErrorMessage = nil
            debugLog("refreshEvents: loaded \(selectedEvents.count) events")
        } catch {
            selectedEvents = []
            lastErrorMessage = "Unable to load events: \(error.localizedDescription)"
            debugLog("refreshEvents: failed with error: \(error.localizedDescription)")
        }
    }

    private static func makeStore() -> (NDJSONEventStore, String?) {
        do {
            return (try NDJSONEventStore(rootDirectory: LogRollerPaths.defaultStorageRoot()), nil)
        } catch {
            let fallbackDirectory = FileManager.default.temporaryDirectory
                .appending(path: "LogRollerFallback", directoryHint: .isDirectory)

            do {
                return (
                    try NDJSONEventStore(rootDirectory: fallbackDirectory),
                    "Using fallback storage at \(fallbackDirectory.path(percentEncoded: false))."
                )
            } catch {
                fatalError("Unable to initialize storage directories: \(error.localizedDescription)")
            }
        }
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print("[LogRoller][AppModel] \(message())")
#endif
    }

    private func startRefreshLoopIfNeeded() {
        guard refreshTask == nil else {
            return
        }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard let self else {
                    return
                }
                await self.refreshRuns()
            }
        }
    }
}
