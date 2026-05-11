import Foundation
import Network

final class NetworkHTTPSServer: @unchecked Sendable {
    typealias RequestHandler = @Sendable (HTTPRequest) async -> HTTPResponse
    static let maximumHeaderBytes = 16 * 1024
    static let maximumBodyBytes = 1 * 1024 * 1024
    static let maximumRequestDuration = Duration.seconds(10)
    static let maximumIdleReceiveDuration = Duration.seconds(2)

    private let requestHandler: RequestHandler
    private let queue = DispatchQueue(label: "org.akuaku.logroller.network-server")
    private var listener: NWListener?

    init(requestHandler: @escaping RequestHandler) {
        self.requestHandler = requestHandler
    }

    func start(port: UInt16, identity: sec_identity_t) throws {
        stop()

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.invalidPort(port)
        }

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity)

        let parameters = NWParameters(tls: tlsOptions, tcp: .init())
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: nwPort)
        let startResult = ListenerStartResult()

        listener.newConnectionHandler = { [weak self] connection in
            fputs("[LogRoller][Server] accepted connection from \(connection.endpoint)\n", stderr)
            self?.handle(connection: connection)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                fputs("[LogRoller][Server] listener ready on port \(port)\n", stderr)
                startResult.complete(.success(()))
            case let .failed(error):
                fputs("[LogRoller][Server] listener failed: \(error)\n", stderr)
                startResult.complete(.failure(ServerError.listenerFailed(error)))
            case .cancelled:
                fputs("[LogRoller][Server] listener cancelled\n", stderr)
                startResult.complete(.failure(ServerError.listenerCancelled))
            default:
                break
            }
        }

        listener.start(queue: queue)

        guard let result = startResult.wait(timeout: .now() + 5) else {
            listener.cancel()
            throw ServerError.startTimedOut(port)
        }

        switch result {
        case .success:
            self.listener = listener
        case let .failure(error):
            listener.cancel()
            throw error
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        let deadline = DispatchTime.now() + Self.maximumRequestDuration.dispatchInterval
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data(), deadline: deadline)
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data, deadline: DispatchTime) {
        let now = DispatchTime.now()
        guard deadline > now else {
            send(response: errorResponse(statusCode: 408, error: "request_timeout"), on: connection)
            return
        }

        let remaining = now.remainingDuration(until: deadline)
        let idleTimeout = Duration.min(Self.maximumIdleReceiveDuration, remaining)
        let timeoutController = ReceiveTimeoutController()
        timeoutController.schedule(on: queue, deadline: now + idleTimeout.dispatchInterval) { [weak self] in
            guard let self else { return }
            self.send(response: self.errorResponse(statusCode: 408, error: "request_timeout"), on: connection)
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            timeoutController.cancel()

            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            switch Self.parseRequest(from: accumulated) {
            case let .success(request):
                fputs("[LogRoller][Server] request \(request.method) \(request.path)\n", stderr)
                Task {
                    let response = await self.requestHandler(request)
                    self.send(response: response, on: connection)
                }
            case .malformed:
                self.send(response: self.errorResponse(statusCode: 400, error: "bad_request"), on: connection)
            case .headerTooLarge:
                self.send(response: self.errorResponse(statusCode: 431, error: "request_header_too_large"), on: connection)
            case .bodyTooLarge:
                self.send(response: self.errorResponse(statusCode: 413, error: "request_body_too_large"), on: connection)
            case .incomplete:
                if error != nil || isComplete {
                    connection.cancel()
                    return
                }
                self.receiveRequest(on: connection, buffer: accumulated, deadline: deadline)
            }
        }
    }

    private func send(response: HTTPResponse, on connection: NWConnection) {
        var headers = response.headers
        if Self.header(named: "Content-Length", in: headers) == nil {
            headers["Content-Length"] = "\(response.body.count)"
        }
        if Self.header(named: "Connection", in: headers) == nil {
            headers["Connection"] = "close"
        }

        var head = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(for: response.statusCode))\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var responseData = Data(head.utf8)
        responseData.append(response.body)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func errorResponse(statusCode: Int, error: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: Data("{\"ok\":false,\"error\":\"\(error)\"}".utf8)
        )
    }

    static func parseRequest(from data: Data) -> ParseResult {
        let headerDelimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerRange = data.range(of: headerDelimiter) else {
            if data.count > maximumHeaderBytes {
                return .headerTooLarge
            }
            return .incomplete
        }

        let headerData = data[..<headerRange.lowerBound]
        if headerData.count > maximumHeaderBytes {
            return .headerTooLarge
        }
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .malformed
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .malformed
        }

        let requestLineParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestLineParts.count >= 2 else {
            return .malformed
        }

        let method = String(requestLineParts[0]).uppercased()
        let rawPath = String(requestLineParts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let headerParts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard headerParts.count == 2 else {
                return .malformed
            }
            let name = String(headerParts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(headerParts[1]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headerRange.upperBound
        guard let contentLength = Int(header(named: "Content-Length", in: headers) ?? "0"), contentLength >= 0 else {
            return .malformed
        }
        if contentLength > maximumBodyBytes {
            return .bodyTooLarge
        }

        let currentBodyBytes = data.count - bodyStart
        if currentBodyBytes > maximumBodyBytes {
            return .bodyTooLarge
        }

        let (requestEnd, overflow) = bodyStart.addingReportingOverflow(contentLength)
        guard !overflow else {
            return .bodyTooLarge
        }
        guard data.count >= requestEnd else {
            return .incomplete
        }

        let body = contentLength > 0
            ? data.subdata(in: bodyStart..<requestEnd)
            : Data()

        return .success(HTTPRequest(method: method, path: path, headers: headers, body: body))
    }

    private static func header(named name: String, in headers: [String: String]) -> String? {
        headers.first { key, _ in key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 408:
            return "Request Timeout"
        case 413:
            return "Payload Too Large"
        case 431:
            return "Request Header Fields Too Large"
        case 404:
            return "Not Found"
        case 500:
            return "Internal Server Error"
        case 503:
            return "Service Unavailable"
        default:
            return "HTTP"
        }
    }

    enum ParseResult {
        case incomplete
        case malformed
        case headerTooLarge
        case bodyTooLarge
        case success(HTTPRequest)
    }

    private enum ServerError: LocalizedError {
        case invalidPort(UInt16)
        case startTimedOut(UInt16)
        case listenerFailed(NWError)
        case listenerCancelled

        var errorDescription: String? {
            switch self {
            case let .invalidPort(port):
                return "Invalid server port: \(port)"
            case let .startTimedOut(port):
                return "HTTPS listener timed out while starting on port \(port)."
            case let .listenerFailed(error):
                return "HTTPS listener failed: \(error)"
            case .listenerCancelled:
                return "HTTPS listener was cancelled before becoming ready."
            }
        }
    }

    private final class ListenerStartResult: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Result<Void, Error>?

        func complete(_ newResult: Result<Void, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard result == nil else {
                return
            }

            result = newResult
            semaphore.signal()
        }

        func wait(timeout: DispatchTime) -> Result<Void, Error>? {
            guard semaphore.wait(timeout: timeout) == .success else {
                return nil
            }

            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    private final class ReceiveTimeoutController: @unchecked Sendable {
        private var workItem: DispatchWorkItem?

        func schedule(on queue: DispatchQueue, deadline: DispatchTime, block: @escaping @Sendable () -> Void) {
            cancel()

            let workItem = DispatchWorkItem(block: block)
            self.workItem = workItem
            queue.asyncAfter(deadline: deadline, execute: workItem)
        }

        func cancel() {
            workItem?.cancel()
            workItem = nil
        }
    }
}

private extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        .milliseconds(Int((components.seconds * 1_000) + (components.attoseconds / 1_000_000_000_000_000)))
    }
}

private extension DispatchTime {
    func remainingDuration(until other: DispatchTime) -> Duration {
        if other.uptimeNanoseconds <= uptimeNanoseconds {
            return .zero
        }
        return .nanoseconds(Int(other.uptimeNanoseconds - uptimeNanoseconds))
    }
}

private extension Duration {
    static func min(_ lhs: Duration, _ rhs: Duration) -> Duration {
        lhs <= rhs ? lhs : rhs
    }
}
