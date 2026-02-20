import Foundation

public struct ServerStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case stopped
        case running
    }

    public var state: State
    public var port: UInt16?
    public var startedAt: Date?

    public var isRunning: Bool {
        state == .running
    }

    public init(state: State, port: UInt16? = nil, startedAt: Date? = nil) {
        self.state = state
        self.port = port
        self.startedAt = startedAt
    }
}

public actor InProcessServerController {
    private let router: LogRollerRouter
    private var status: ServerStatus = .init(state: .stopped)
    private var networkServer: NetworkHTTPSServer?
    private var lastStartError: String?

    public init(router: LogRollerRouter) {
        self.router = router
    }

    public func start(port: UInt16) {
        fputs("[LogRoller][Server] starting HTTPS listener on port \(port)\n", stderr)
        stop()

        do {
            let identity = try TLSIdentityProvider().loadOrCreateIdentity()
            fputs("[LogRoller][Server] TLS identity ready\n", stderr)
            let startedAt = Date.now
            let router = self.router
            let server = NetworkHTTPSServer { request in
                await router.route(request, serverStartedAt: startedAt)
            }
            try server.start(port: port, identity: identity)

            networkServer = server
            status = ServerStatus(state: .running, port: port, startedAt: startedAt)
            lastStartError = nil
            fputs("[LogRoller][Server] HTTPS listener running on port \(port)\n", stderr)
        } catch {
            networkServer = nil
            status = ServerStatus(state: .stopped)
            lastStartError = error.localizedDescription
            fputs("[LogRoller][Server] start failed: \(error.localizedDescription)\n", stderr)
        }
    }

    public func stop() {
        networkServer?.stop()
        networkServer = nil
        status = ServerStatus(state: .stopped)
    }

    public func currentStatus() -> ServerStatus {
        status
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard status.isRunning else {
            let body = Data("{\"ok\":false,\"error\":\"server_not_running\"}".utf8)
            return HTTPResponse(statusCode: 503, headers: ["Content-Type": "application/json"], body: body)
        }

        return await router.route(request, serverStartedAt: status.startedAt)
    }

    public func currentStartError() -> String? {
        lastStartError
    }
}
