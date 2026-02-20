import Foundation
import LogRollerCore

public actor LogRollerRouter {
    private let store: any EventStore
    private let appVersion: String

    public init(store: any EventStore, appVersion: String = "0.1.0") {
        self.store = store
        self.appVersion = appVersion
    }

    public func route(_ request: HTTPRequest, serverStartedAt: Date?) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"):
            return homeResponse(for: request, startedAt: serverStartedAt)
        case ("GET", "/healthz"):
            return healthResponse(startedAt: serverStartedAt)
        case ("POST", "/ingest"):
            return await ingestResponse(for: request.body)
        default:
            return jsonResponse(statusCode: 404, payload: APIErrorResponse(error: "not_found"))
        }
    }

    private func homeResponse(for request: HTTPRequest, startedAt: Date?) -> HTTPResponse {
        let uptimeSeconds = startedAt.map { max(0, Int(Date.now.timeIntervalSince($0))) } ?? 0
        let host = headerValue(named: "Host", in: request.headers) ?? "<mac-host>:8443"
        let baseURL = "https://\(host)"
        let body = """
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>LogRoller Server</title>
            <style>
              body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 2rem; line-height: 1.4; color: #1f2937; }
              h1 { margin: 0 0 0.75rem 0; }
              code { background: #f3f4f6; padding: 0.1rem 0.35rem; border-radius: 0.25rem; }
              .muted { color: #6b7280; }
            </style>
          </head>
          <body>
            <h1>LogRoller ingest server is running</h1>
            <p>Use the Desktop app or <code>logroller</code> CLI to browse events.</p>
            <p>Base URL: <code>\(baseURL)</code></p>
            <p>Endpoints: <code>POST /ingest</code>, <code>GET /healthz</code></p>
            <p class="muted">App version \(appVersion) • uptime \(uptimeSeconds)s</p>
          </body>
        </html>
        """
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"],
            body: Data(body.utf8)
        )
    }

    private func healthResponse(startedAt: Date?) -> HTTPResponse {
        let uptime = startedAt.map { max(0, Date.now.timeIntervalSince($0)) } ?? 0
        let payload = HealthzResponse(version: appVersion, uptimeS: uptime)
        return jsonResponse(statusCode: 200, payload: payload)
    }

    private func ingestResponse(for data: Data) async -> HTTPResponse {
        let decoder = LogRollerJSONCoders.decoder

        do {
            let batch: IngestBatchPayload
            if let decodedBatch = try? decoder.decode(IngestBatchPayload.self, from: data) {
                batch = decodedBatch
            } else if let singleEvent = try? decoder.decode(IncomingEvent.self, from: data) {
                batch = IngestBatchPayload(runID: singleEvent.runID, deviceID: singleEvent.deviceID, events: [singleEvent])
            } else {
                return jsonResponse(statusCode: 400, payload: APIErrorResponse(error: "invalid_json_payload"))
            }

            guard !batch.events.isEmpty else {
                return jsonResponse(statusCode: 400, payload: APIErrorResponse(error: "events_must_not_be_empty"))
            }

            let receipt = try await store.ingest(batch: batch, receiveDate: .now)
            return jsonResponse(statusCode: 200, payload: receipt)
        } catch {
            return jsonResponse(
                statusCode: 500,
                payload: APIErrorResponse(error: "ingest_failed", message: error.localizedDescription)
            )
        }
    }

    private func jsonResponse<T: Encodable>(statusCode: Int, payload: T) -> HTTPResponse {
        do {
            let body = try LogRollerJSONCoders.encoder.encode(payload)
            return HTTPResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: body)
        } catch {
            let fallback = Data("{\"ok\":false,\"error\":\"encoding_failed\"}".utf8)
            return HTTPResponse(statusCode: 500, headers: ["Content-Type": "application/json"], body: fallback)
        }
    }

    private func headerValue(named name: String, in headers: [String: String]) -> String? {
        headers.first { key, _ in key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
