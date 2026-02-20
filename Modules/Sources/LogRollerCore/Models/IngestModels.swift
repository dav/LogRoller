import Foundation

public enum LogEventLevel: String, Codable, Sendable, CaseIterable {
    case debug
    case info
    case warn
    case error
}

public struct IncomingEvent: Codable, Sendable, Equatable {
    public var ts: Date
    public var level: LogEventLevel
    public var event: String
    public var runID: String?
    public var deviceID: String?
    public var seq: Int?
    public var payload: JSONValue
    public var app: JSONValue?
    public var context: JSONValue?

    public init(
        ts: Date,
        level: LogEventLevel,
        event: String,
        runID: String? = nil,
        deviceID: String? = nil,
        seq: Int? = nil,
        payload: JSONValue,
        app: JSONValue? = nil,
        context: JSONValue? = nil
    ) {
        self.ts = ts
        self.level = level
        self.event = event
        self.runID = runID
        self.deviceID = deviceID
        self.seq = seq
        self.payload = payload
        self.app = app
        self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case ts
        case level
        case event
        case runID = "run_id"
        case deviceID = "device_id"
        case seq
        case payload
        case app
        case context
    }
}

public struct IngestBatchPayload: Codable, Sendable, Equatable {
    public var runID: String?
    public var deviceID: String?
    public var events: [IncomingEvent]

    public init(runID: String? = nil, deviceID: String? = nil, events: [IncomingEvent]) {
        self.runID = runID
        self.deviceID = deviceID
        self.events = events
    }

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case deviceID = "device_id"
        case events
    }
}

public struct StoredEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var runID: String
    public var deviceID: String
    public var ts: Date
    public var recvTS: Date
    public var level: LogEventLevel
    public var event: String
    public var seq: Int?
    public var payload: JSONValue
    public var app: JSONValue?
    public var context: JSONValue?

    public init(
        id: UUID = UUID(),
        runID: String,
        deviceID: String,
        ts: Date,
        recvTS: Date,
        level: LogEventLevel,
        event: String,
        seq: Int?,
        payload: JSONValue,
        app: JSONValue?,
        context: JSONValue?
    ) {
        self.id = id
        self.runID = runID
        self.deviceID = deviceID
        self.ts = ts
        self.recvTS = recvTS
        self.level = level
        self.event = event
        self.seq = seq
        self.payload = payload
        self.app = app
        self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case id
        case runID = "run_id"
        case deviceID = "device_id"
        case ts
        case recvTS = "recv_ts"
        case level
        case event
        case seq
        case payload
        case app
        case context
    }
}

public struct IngestReceipt: Codable, Sendable, Equatable {
    public var ok: Bool
    public var stored: Int
    public var runID: String
    public var deviceID: String

    public init(ok: Bool = true, stored: Int, runID: String, deviceID: String) {
        self.ok = ok
        self.stored = stored
        self.runID = runID
        self.deviceID = deviceID
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case stored
        case runID = "run_id"
        case deviceID = "device_id"
    }
}

public struct RunSummary: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var runID: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deviceCount: Int
    public var eventCount: Int
    public var errorCount: Int

    public var id: String { runID }

    public init(runID: String, createdAt: Date, updatedAt: Date, deviceCount: Int, eventCount: Int, errorCount: Int) {
        self.runID = runID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deviceCount = deviceCount
        self.eventCount = eventCount
        self.errorCount = errorCount
    }

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deviceCount = "device_count"
        case eventCount = "event_count"
        case errorCount = "error_count"
    }
}

public struct DeviceSummary: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var deviceID: String
    public var lastSeenAt: Date
    public var eventCount: Int

    public var id: String { deviceID }

    public init(deviceID: String, lastSeenAt: Date, eventCount: Int) {
        self.deviceID = deviceID
        self.lastSeenAt = lastSeenAt
        self.eventCount = eventCount
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case lastSeenAt = "last_seen_at"
        case eventCount = "event_count"
    }
}
