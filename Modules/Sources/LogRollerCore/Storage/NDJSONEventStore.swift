import Foundation

public actor NDJSONEventStore: EventStore {
    private struct MutableDeviceSummary {
        var lastSeenAt: Date
        var eventCount: Int
    }

    private struct MutableRunSummary {
        var createdAt: Date
        var updatedAt: Date
        var eventCount: Int
        var errorCount: Int
        var devices: [String: MutableDeviceSummary]
    }

    private struct StoredRunSummary: Codable {
        struct Device: Codable {
            let deviceID: String
            let lastSeenAt: Date
            let eventCount: Int

            enum CodingKeys: String, CodingKey {
                case deviceID = "device_id"
                case lastSeenAt = "last_seen_at"
                case eventCount = "event_count"
            }
        }

        let runID: String
        let createdAt: Date
        let updatedAt: Date
        let eventCount: Int
        let errorCount: Int
        let devices: [Device]

        enum CodingKeys: String, CodingKey {
            case runID = "run_id"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case eventCount = "event_count"
            case errorCount = "error_count"
            case devices
        }
    }

    private static let summaryFilename = "summary.json"

    private let rootDirectory: URL
    private let fileManager = FileManager.default
    private var runIndex: [String: MutableRunSummary] = [:]
    private var indexLoaded = false

    public init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        Self.debugLog("Initialized store at \(Self.fileSystemPath(rootDirectory))")
    }

    public func ingest(batch: IngestBatchPayload, receiveDate: Date = .now) async throws -> IngestReceipt {
        ensureIndexLoaded()

        let runIDFallback = batch.runID ?? fallbackRunID(now: receiveDate)
        let deviceIDFallback = batch.deviceID ?? "unknown_device"

        var firstRunID = runIDFallback
        var firstDeviceID = deviceIDFallback
        var storedEvents = 0
        var touchedRunIDs: Set<String> = []

        for incoming in batch.events {
            let runID = normalizedID(incoming.runID ?? batch.runID ?? runIDFallback, fallback: runIDFallback)
            let deviceID = normalizedID(incoming.deviceID ?? batch.deviceID ?? deviceIDFallback, fallback: deviceIDFallback)

            let stored = StoredEvent(
                runID: runID,
                deviceID: deviceID,
                ts: incoming.ts,
                recvTS: receiveDate,
                level: incoming.level,
                event: incoming.event,
                seq: incoming.seq,
                payload: incoming.payload,
                app: incoming.app,
                context: incoming.context,
                resources: incoming.resources,
                traceID: incoming.traceID
            )

            try append(event: stored)
            updateRunIndex(event: stored)
            touchedRunIDs.insert(runID)

            if storedEvents == 0 {
                firstRunID = runID
                firstDeviceID = deviceID
            }

            storedEvents += 1
        }

        for runID in touchedRunIDs {
            persistSummary(forRunID: runID)
        }

        Self.debugLog("Ingested batch: stored=\(storedEvents), run=\(firstRunID), device=\(firstDeviceID)")
        return IngestReceipt(stored: storedEvents, runID: firstRunID, deviceID: firstDeviceID)
    }

    public func listRuns(limit: Int = 100) async -> [RunSummary] {
        ensureIndexLoaded()

        let runs = runIndex.map { runID, entry in
            RunSummary(
                runID: runID,
                createdAt: entry.createdAt,
                updatedAt: entry.updatedAt,
                deviceCount: entry.devices.count,
                eventCount: entry.eventCount,
                errorCount: entry.errorCount
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
        .prefix(limit)
        .map { $0 }

        Self.debugLog("listRuns(limit: \(limit)) -> \(runs.count) runs")
        return runs
    }

    public func listDevices(runID: String) async -> [DeviceSummary] {
        ensureIndexLoaded()

        guard let entry = runIndex[runID] else {
            Self.debugLog("listDevices(runID: \(runID)) -> 0 devices (run missing in index)")
            return []
        }

        let devices = entry.devices.map { deviceID, device in
            DeviceSummary(deviceID: deviceID, lastSeenAt: device.lastSeenAt, eventCount: device.eventCount)
        }
        .sorted { $0.lastSeenAt > $1.lastSeenAt }

        Self.debugLog("listDevices(runID: \(runID)) -> \(devices.count) devices")
        return devices
    }

    public func events(runID: String, deviceID: String?, limit: Int = 500) async throws -> [StoredEvent] {
        // Intentionally does not load the run index — this path only needs the files under one run directory.
        let runDirectory = rootDirectory.appending(path: runID, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: Self.fileSystemPath(runDirectory)) else {
            Self.debugLog("events(runID: \(runID), deviceID: \(deviceID ?? "all")) -> 0 (run directory missing at \(Self.fileSystemPath(runDirectory)))")
            return []
        }

        let files: [URL]
        if let deviceID {
            files = [runDirectory.appending(path: "\(deviceID).ndjson")]
        } else {
            files = try fileManager.contentsOfDirectory(at: runDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "ndjson" }
        }

        var totalLines = 0
        var decodedRows = 0
        var fallbackRows = 0
        var filteredRows = 0
        var droppedRows = 0

        var collected: [StoredEvent] = []
        for file in files {
            guard fileManager.fileExists(atPath: Self.fileSystemPath(file)) else {
                Self.debugLog("events(runID: \(runID)) skipped missing file: \(file.lastPathComponent)")
                continue
            }
            let fallbackDeviceID = file.deletingPathExtension().lastPathComponent

            let data = try Data(contentsOf: file)
            guard let text = String(data: data, encoding: .utf8) else {
                Self.debugLog("events(runID: \(runID)) skipped non-UTF8 file: \(file.lastPathComponent)")
                continue
            }

            for (lineIndex, line) in text.split(separator: "\n").enumerated() {
                guard !line.isEmpty else {
                    continue
                }
                totalLines += 1
                guard let lineData = line.data(using: .utf8) else {
                    droppedRows += 1
                    continue
                }

                if var event = decodeStoredEvent(from: lineData) {
                    // Keep event rendering usable even for legacy lines with missing IDs.
                    if event.runID.isEmpty {
                        event.runID = runID
                    }
                    if event.deviceID.isEmpty {
                        event.deviceID = fallbackDeviceID
                    }
                    if let deviceID, event.deviceID != deviceID {
                        filteredRows += 1
                        continue
                    }
                    collected.append(event)
                    decodedRows += 1
                    continue
                }

                guard let rawLine = String(data: lineData, encoding: .utf8),
                      let fallbackEvent = Self.unparsedEvent(
                        from: rawLine,
                        runID: runID,
                        fallbackDeviceID: fallbackDeviceID,
                        lineNumber: lineIndex + 1
                      ) else {
                    droppedRows += 1
                    continue
                }
                if let deviceID, fallbackEvent.deviceID != deviceID {
                    filteredRows += 1
                    continue
                }
                collected.append(fallbackEvent)
                fallbackRows += 1
            }
        }

        let result = collected
            .sorted { $0.ts > $1.ts }
            .prefix(limit)
            .map { $0 }
        Self.debugLog(
            "events(runID: \(runID), deviceID: \(deviceID ?? "all"), limit: \(limit)) files=\(files.count), lines=\(totalLines), decoded=\(decodedRows), fallback=\(fallbackRows), filtered=\(filteredRows), dropped=\(droppedRows), returned=\(result.count)"
        )
        return result
    }

    public func deleteRun(runID: String) async throws {
        let runDirectory = rootDirectory.appending(path: runID, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: Self.fileSystemPath(runDirectory)) {
            try fileManager.removeItem(at: runDirectory)
        }
        if indexLoaded {
            runIndex.removeValue(forKey: runID)
        }
        Self.debugLog("deleteRun(runID: \(runID)) completed")
    }

    public func storageRootPath() -> String {
        Self.fileSystemPath(rootDirectory)
    }

    private func append(event: StoredEvent) throws {
        let runDirectory = rootDirectory.appending(path: event.runID, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        let fileURL = runDirectory.appending(path: "\(event.deviceID).ndjson")
        let eventData = try LogRollerJSONCoders.encoder.encode(event)
        var line = eventData
        line.append(0x0A)

        if fileManager.fileExists(atPath: Self.fileSystemPath(fileURL)) {
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            defer {
                try? fileHandle.close()
            }
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: line)
        } else {
            try line.write(to: fileURL)
        }
    }

    private func updateRunIndex(event: StoredEvent) {
        Self.update(index: &runIndex, with: event)
    }

    private static func update(index: inout [String: MutableRunSummary], with event: StoredEvent) {
        var runEntry = index[event.runID] ?? MutableRunSummary(
            createdAt: event.recvTS,
            updatedAt: event.recvTS,
            eventCount: 0,
            errorCount: 0,
            devices: [:]
        )

        runEntry.updatedAt = max(runEntry.updatedAt, event.recvTS)
        runEntry.eventCount += 1
        if event.level == .error {
            runEntry.errorCount += 1
        }

        var deviceEntry = runEntry.devices[event.deviceID] ?? MutableDeviceSummary(lastSeenAt: event.recvTS, eventCount: 0)
        deviceEntry.lastSeenAt = max(deviceEntry.lastSeenAt, event.recvTS)
        deviceEntry.eventCount += 1

        runEntry.devices[event.deviceID] = deviceEntry
        index[event.runID] = runEntry
    }

    private func normalizedID(_ value: String, fallback: String) -> String {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? fallback : candidate
    }

    private func fallbackRunID(now: Date) -> String {
        let stamp = LogRollerJSONCoders.render(date: now).replacing(":", with: "-")
        return "run_\(stamp)"
    }

    // MARK: - Index loading

    private func ensureIndexLoaded() {
        guard !indexLoaded else { return }
        do {
            runIndex = try Self.loadIndex(rootDirectory: rootDirectory, fileManager: fileManager)
            indexLoaded = true
            Self.debugLog("Loaded run index with \(runIndex.count) runs")
        } catch {
            Self.debugLog("Failed to load run index: \(error.localizedDescription); continuing with empty index")
        }
    }

    private static func loadIndex(rootDirectory: URL, fileManager: FileManager) throws -> [String: MutableRunSummary] {
        var index: [String: MutableRunSummary] = [:]
        let runDirectories = try fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey])

        for runDirectory in runDirectories {
            let values = try? runDirectory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else {
                continue
            }

            let runID = runDirectory.lastPathComponent
            if let summary = resolveSummary(runDirectory: runDirectory, runID: runID, fileManager: fileManager) {
                index[runID] = summary
            }
        }

        return index
    }

    private static func resolveSummary(runDirectory: URL, runID: String, fileManager: FileManager) -> MutableRunSummary? {
        let summaryURL = runDirectory.appending(path: summaryFilename)
        let summaryMTime = mtime(of: summaryURL, fileManager: fileManager)
        let newestEventMTime = newestNDJSONMTime(in: runDirectory, fileManager: fileManager)

        // Trust the sidecar when it is at least as new as the most recent event file
        // (or when there are no event files at all).
        let sidecarIsFresh: Bool = {
            guard let summaryMTime else { return false }
            guard let newestEventMTime else { return true }
            return summaryMTime >= newestEventMTime
        }()

        if sidecarIsFresh, let stored = readSummarySidecar(at: summaryURL) {
            return mutableSummary(from: stored)
        }

        guard let rebuilt = rebuildSummary(runDirectory: runDirectory, runID: runID, fileManager: fileManager) else {
            return nil
        }
        try? writeSummarySidecar(rebuilt, runID: runID, runDirectory: runDirectory)
        return rebuilt
    }

    private static func rebuildSummary(runDirectory: URL, runID: String, fileManager: FileManager) -> MutableRunSummary? {
        guard let deviceFiles = try? fileManager.contentsOfDirectory(at: runDirectory, includingPropertiesForKeys: nil) else {
            return nil
        }

        var scratch: [String: MutableRunSummary] = [:]
        for deviceFile in deviceFiles where deviceFile.pathExtension == "ndjson" {
            let fallbackDeviceID = deviceFile.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: deviceFile),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }

            for line in text.split(separator: "\n") {
                guard !line.isEmpty else {
                    continue
                }
                guard let lineData = line.data(using: .utf8) else {
                    continue
                }
                guard var event = decodeStoredEvent(from: lineData) else {
                    continue
                }

                if event.runID.isEmpty {
                    event.runID = runID
                }
                if event.deviceID.isEmpty {
                    event.deviceID = fallbackDeviceID
                }
                update(index: &scratch, with: event)
            }
        }

        return scratch[runID]
    }

    // MARK: - Sidecar I/O

    private func persistSummary(forRunID runID: String) {
        guard let entry = runIndex[runID] else { return }
        let runDirectory = rootDirectory.appending(path: runID, directoryHint: .isDirectory)
        do {
            try Self.writeSummarySidecar(entry, runID: runID, runDirectory: runDirectory)
        } catch {
            Self.debugLog("persistSummary(runID: \(runID)) failed: \(error.localizedDescription)")
        }
    }

    private static func writeSummarySidecar(_ summary: MutableRunSummary, runID: String, runDirectory: URL) throws {
        let stored = StoredRunSummary(
            runID: runID,
            createdAt: summary.createdAt,
            updatedAt: summary.updatedAt,
            eventCount: summary.eventCount,
            errorCount: summary.errorCount,
            devices: summary.devices.map { deviceID, device in
                StoredRunSummary.Device(
                    deviceID: deviceID,
                    lastSeenAt: device.lastSeenAt,
                    eventCount: device.eventCount
                )
            }
        )
        let data = try LogRollerJSONCoders.encoder.encode(stored)
        let url = runDirectory.appending(path: summaryFilename)
        try data.write(to: url, options: .atomic)
    }

    private static func readSummarySidecar(at url: URL) -> StoredRunSummary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? LogRollerJSONCoders.decoder.decode(StoredRunSummary.self, from: data)
    }

    private static func mutableSummary(from stored: StoredRunSummary) -> MutableRunSummary {
        var devices: [String: MutableDeviceSummary] = [:]
        for device in stored.devices {
            devices[device.deviceID] = MutableDeviceSummary(
                lastSeenAt: device.lastSeenAt,
                eventCount: device.eventCount
            )
        }
        return MutableRunSummary(
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt,
            eventCount: stored.eventCount,
            errorCount: stored.errorCount,
            devices: devices
        )
    }

    private static func mtime(of url: URL, fileManager: FileManager) -> Date? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: fileSystemPath(url)) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    private static func newestNDJSONMTime(in runDirectory: URL, fileManager: FileManager) -> Date? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: runDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return nil
        }
        var newest: Date?
        for file in files where file.pathExtension == "ndjson" {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = values?.contentModificationDate else {
                continue
            }
            if let current = newest {
                if date > current { newest = date }
            } else {
                newest = date
            }
        }
        return newest
    }

    // MARK: - Event decoding

    private func decodeStoredEvent(from data: Data) -> StoredEvent? {
        Self.decodeStoredEvent(from: data)
    }

    private static func decodeStoredEvent(from data: Data) -> StoredEvent? {
        if let event = try? LogRollerJSONCoders.decoder.decode(StoredEvent.self, from: data) {
            return event
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        return legacyEvent(from: dictionary)
    }

    private static func legacyEvent(from dictionary: [String: Any]) -> StoredEvent? {
        let runID = string(forCanonical: "runid", in: dictionary) ?? ""
        let deviceID = string(forCanonical: "deviceid", in: dictionary) ?? ""
        let eventName = string(forCanonical: "event", in: dictionary) ?? "unknown"
        let levelRaw = string(forCanonical: "level", in: dictionary) ?? LogEventLevel.info.rawValue
        let level = LogEventLevel(rawValue: levelRaw) ?? .info

        let tsString = string(forCanonical: "ts", in: dictionary)
        let recvTSString = string(forCanonical: "recvts", in: dictionary)
        let ts = tsString.flatMap(LogRollerJSONCoders.parse(dateString:)) ?? .now
        let recvTS = recvTSString.flatMap(LogRollerJSONCoders.parse(dateString:)) ?? ts

        let seq = int(forCanonical: "seq", in: dictionary)
        let payload = value(forCanonical: "payload", in: dictionary).flatMap(jsonValue(from:)) ?? .object([:])
        let app = value(forCanonical: "app", in: dictionary).flatMap(jsonValue(from:))
        let context = value(forCanonical: "context", in: dictionary).flatMap(jsonValue(from:))
        let resources = value(forCanonical: "resources", in: dictionary).flatMap(jsonValue(from:))
        let traceID = string(forCanonical: "traceid", in: dictionary)

        let id: UUID
        if let idString = string(forCanonical: "id", in: dictionary), let parsed = UUID(uuidString: idString) {
            id = parsed
        } else {
            id = UUID()
        }

        return StoredEvent(
            id: id,
            runID: runID,
            deviceID: deviceID,
            ts: ts,
            recvTS: recvTS,
            level: level,
            event: eventName,
            seq: seq,
            payload: payload,
            app: app,
            context: context,
            resources: resources,
            traceID: traceID
        )
    }

    private static func value(forCanonical canonicalKey: String, in dictionary: [String: Any]) -> Any? {
        let canonical = canonicalize(key: canonicalKey)
        for (key, value) in dictionary {
            if canonicalize(key: key) == canonical {
                return value
            }
        }
        return nil
    }

    private static func string(forCanonical canonicalKey: String, in dictionary: [String: Any]) -> String? {
        value(forCanonical: canonicalKey, in: dictionary) as? String
    }

    private static func int(forCanonical canonicalKey: String, in dictionary: [String: Any]) -> Int? {
        if let value = value(forCanonical: canonicalKey, in: dictionary) as? Int {
            return value
        }
        if let value = value(forCanonical: canonicalKey, in: dictionary) as? NSNumber {
            return value.intValue
        }
        if let value = value(forCanonical: canonicalKey, in: dictionary) as? String {
            return Int(value)
        }
        return nil
    }

    private static func canonicalize(key: String) -> String {
        let scalars = key.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    private static func unparsedEvent(from line: String, runID: String, fallbackDeviceID: String, lineNumber: Int) -> StoredEvent? {
        let lineData = Data(line.utf8)

        guard let object = try? JSONSerialization.jsonObject(with: lineData),
              let dictionary = object as? [String: Any] else {
            return StoredEvent(
                runID: runID,
                deviceID: fallbackDeviceID,
                ts: .now,
                recvTS: .now,
                level: .warn,
                event: "storage.unparsed_row",
                seq: nil,
                payload: .object([
                    "line_number": .number(Double(lineNumber)),
                    "raw_row": .string(line),
                ]),
                app: nil,
                context: nil
            )
        }

        let parsedRunID = string(forCanonical: "runid", in: dictionary) ?? runID
        let parsedDeviceID = string(forCanonical: "deviceid", in: dictionary) ?? fallbackDeviceID
        let eventName = string(forCanonical: "event", in: dictionary) ?? "storage.unparsed_row"
        let levelRaw = string(forCanonical: "level", in: dictionary) ?? LogEventLevel.warn.rawValue
        let level = LogEventLevel(rawValue: levelRaw) ?? .warn

        let ts = date(
            from: dictionary,
            primaryCanonicalKey: "ts",
            fallbackCanonicalKeys: ["timestamp", "time"],
            defaultValue: .now
        )
        let recvTS = date(
            from: dictionary,
            primaryCanonicalKey: "recvts",
            fallbackCanonicalKeys: ["receivedat", "ingestedat"],
            defaultValue: ts
        )

        let seq = int(forCanonical: "seq", in: dictionary)
        var payload = value(forCanonical: "payload", in: dictionary).flatMap(jsonValue(from:))
        if payload == nil {
            payload = .object([
                "line_number": .number(Double(lineNumber)),
                "raw_row": .string(line),
            ])
        }

        let app = value(forCanonical: "app", in: dictionary).flatMap(jsonValue(from:))
        let context = value(forCanonical: "context", in: dictionary).flatMap(jsonValue(from:))
        let resources = value(forCanonical: "resources", in: dictionary).flatMap(jsonValue(from:))
        let traceID = string(forCanonical: "traceid", in: dictionary)

        let id: UUID
        if let idString = string(forCanonical: "id", in: dictionary), let parsed = UUID(uuidString: idString) {
            id = parsed
        } else {
            id = UUID()
        }

        return StoredEvent(
            id: id,
            runID: parsedRunID,
            deviceID: parsedDeviceID,
            ts: ts,
            recvTS: recvTS,
            level: level,
            event: eventName,
            seq: seq,
            payload: payload ?? .object([:]),
            app: app,
            context: context,
            resources: resources,
            traceID: traceID
        )
    }

    private static func date(
        from dictionary: [String: Any],
        primaryCanonicalKey: String,
        fallbackCanonicalKeys: [String],
        defaultValue: Date
    ) -> Date {
        if let value = string(forCanonical: primaryCanonicalKey, in: dictionary),
           let parsed = LogRollerJSONCoders.parse(dateString: value) {
            return parsed
        }

        for key in fallbackCanonicalKeys {
            if let value = string(forCanonical: key, in: dictionary),
               let parsed = LogRollerJSONCoders.parse(dateString: value) {
                return parsed
            }
        }

        return defaultValue
    }

    private static func jsonValue(from any: Any) -> JSONValue? {
        switch any {
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as [String: Any]:
            let pairs = value.compactMapValues(jsonValue(from:))
            return .object(pairs)
        case let value as [Any]:
            return .array(value.compactMap(jsonValue(from:)))
        default:
            return .null
        }
    }

    private static func debugLog(_ message: String) {
#if DEBUG
        fputs("[LogRoller][Store] \(message)\n", stderr)
#endif
    }

    private static func fileSystemPath(_ url: URL) -> String {
        url.path(percentEncoded: false)
    }
}
