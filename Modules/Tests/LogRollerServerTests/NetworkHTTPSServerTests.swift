import Foundation
import Testing
@testable import LogRollerServer

@Suite
struct NetworkHTTPSServerTests {
    @Test
    func parseRequestAcceptsBodyAtConfiguredLimit() {
        let body = String(repeating: "a", count: NetworkHTTPSServer.maximumBodyBytes)
        let request = """
        POST /ingest HTTP/1.1\r
        Host: localhost\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """

        switch NetworkHTTPSServer.parseRequest(from: Data(request.utf8)) {
        case let .success(parsedRequest):
            #expect(parsedRequest.method == "POST")
            #expect(parsedRequest.path == "/ingest")
            #expect(parsedRequest.body.count == body.utf8.count)
        default:
            Issue.record("Expected parser to accept a request whose body is exactly at the configured limit.")
        }
    }

    @Test
    func parseRequestRejectsOversizedHeaders() {
        let oversizedHeaders = Data(repeating: 0x61, count: NetworkHTTPSServer.maximumHeaderBytes + 1)

        switch NetworkHTTPSServer.parseRequest(from: oversizedHeaders) {
        case .headerTooLarge:
            break
        default:
            Issue.record("Expected oversized headers to be rejected.")
        }
    }

    @Test
    func parseRequestRejectsOversizedContentLength() {
        let request =
            "POST /ingest HTTP/1.1\r\n" +
            "Host: localhost\r\n" +
            "Content-Length: \(NetworkHTTPSServer.maximumBodyBytes + 1)\r\n" +
            "\r\n"

        switch NetworkHTTPSServer.parseRequest(from: Data(request.utf8)) {
        case .bodyTooLarge:
            break
        default:
            Issue.record("Expected oversized content length to be rejected.")
        }
    }

    @Test
    func parseRequestRejectsInvalidContentLength() {
        let request =
            "POST /ingest HTTP/1.1\r\n" +
            "Host: localhost\r\n" +
            "Content-Length: nope\r\n" +
            "\r\n"

        switch NetworkHTTPSServer.parseRequest(from: Data(request.utf8)) {
        case .malformed:
            break
        default:
            Issue.record("Expected invalid content length to be treated as a malformed request.")
        }
    }
}
