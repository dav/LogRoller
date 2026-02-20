import Foundation
import Network

final class NetworkHTTPSServer: @unchecked Sendable {
    typealias RequestHandler = @Sendable (HTTPRequest) async -> HTTPResponse

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
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

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
                let response = HTTPResponse(
                    statusCode: 400,
                    headers: ["Content-Type": "application/json"],
                    body: Data("{\"ok\":false,\"error\":\"bad_request\"}".utf8)
                )
                self.send(response: response, on: connection)
            case .incomplete:
                if error != nil || isComplete {
                    connection.cancel()
                    return
                }
                self.receiveRequest(on: connection, buffer: accumulated)
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

    private static func parseRequest(from data: Data) -> ParseResult {
        let headerDelimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerRange = data.range(of: headerDelimiter) else {
            return .incomplete
        }

        let headerData = data[..<headerRange.lowerBound]
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
        let contentLength = Int(header(named: "Content-Length", in: headers) ?? "0") ?? 0
        guard data.count >= bodyStart + contentLength else {
            return .incomplete
        }

        let body = contentLength > 0
            ? data.subdata(in: bodyStart..<(bodyStart + contentLength))
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

    private enum ParseResult {
        case incomplete
        case malformed
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
}
