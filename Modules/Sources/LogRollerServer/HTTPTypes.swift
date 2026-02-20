import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public struct HealthzResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var version: String
    public var uptimeS: TimeInterval

    public init(ok: Bool = true, version: String, uptimeS: TimeInterval) {
        self.ok = ok
        self.version = version
        self.uptimeS = uptimeS
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case version
        case uptimeS = "uptime_s"
    }
}

public struct APIErrorResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String
    public var message: String?

    public init(ok: Bool = false, error: String, message: String? = nil) {
        self.ok = ok
        self.error = error
        self.message = message
    }
}
