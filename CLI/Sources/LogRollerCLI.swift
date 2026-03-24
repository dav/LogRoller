import Foundation
import LogRollerCore

@main
struct LogRollerCLI {
    private static let defaultServerPort: UInt16 = 8443

    private enum OutputFormat {
        case markdown
        case json
    }

    private struct EventsOptions {
        var runID: String?
        var deviceID: String?
        var limit: Int = 200
        var useNDJSON = false
    }

    private struct IngestHelpOptions {
        var outputFormat: OutputFormat = .markdown
    }

    private struct EventsResponse: Encodable {
        var ok = true
        var runID: String
        var deviceID: String?
        var count: Int
        var events: [StoredEvent]

        enum CodingKeys: String, CodingKey {
            case ok
            case runID = "run_id"
            case deviceID = "device_id"
            case count
            case events
        }
    }

    private struct IngestHelpResponse: Encodable {
        var ok = true
        var baseURL: String
        var candidateBaseURLs: [String]
        var defaultPort: UInt16
        var endpoint: String
        var method: String
        var contentType: String
        var accepts: [String]
        var requiredEventFields: [Field]
        var optionalEventFields: [Field]
        var fieldFallbacks: [String]
        var responseShape: String
        var healthEndpoint: String
        var curlBatchExample: String
        var curlSingleEventExample: String
        var notes: [String]

        struct Field: Encodable {
            var name: String
            var type: String
            var description: String
        }

        enum CodingKeys: String, CodingKey {
            case ok
            case baseURL = "base_url"
            case candidateBaseURLs = "candidate_base_urls"
            case defaultPort = "default_port"
            case endpoint
            case method
            case contentType = "content_type"
            case accepts
            case requiredEventFields = "required_event_fields"
            case optionalEventFields = "optional_event_fields"
            case fieldFallbacks = "field_fallbacks"
            case responseShape = "response_shape"
            case healthEndpoint = "health_endpoint"
            case curlBatchExample = "curl_batch_example"
            case curlSingleEventExample = "curl_single_event_example"
            case notes
        }
    }

    private struct StatusResponse: Encodable {
        var ok = true
        var storagePath: String
        var hasRuns: Bool
        var serverPort: UInt16
        var serverActive: Bool
        var activeBaseURL: String?
        var healthURL: String?
        var healthStatusCode: Int?
        var serverError: String?

        enum CodingKeys: String, CodingKey {
            case ok
            case storagePath = "storage_path"
            case hasRuns = "has_runs"
            case serverPort = "server_port"
            case serverActive = "server_active"
            case activeBaseURL = "active_base_url"
            case healthURL = "health_url"
            case healthStatusCode = "health_status_code"
            case serverError = "server_error"
        }
    }

    private struct ServerProbeResult: Sendable {
        var isActive: Bool
        var baseURL: String?
        var healthURL: String?
        var statusCode: Int?
        var error: String?
    }

    private struct HealthPayload: Decodable {
        var ok: Bool
    }

    private final class LocalTLSTrustDelegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                return (.performDefaultHandling, nil)
            }

            return (.useCredential, URLCredential(trust: trust))
        }
    }

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        guard let command = arguments.first else {
            printUsage()
            Foundation.exit(1)
        }

        switch command {
        case "status":
            await printStatus()
        case "events":
            await printEvents(arguments: Array(arguments.dropFirst()))
        case "ingest-help":
            printIngestHelp(arguments: Array(arguments.dropFirst()))
        default:
            printUsage()
            Foundation.exit(1)
        }
    }

    private static func printStatus() async {
        let store = makeStoreOrExit()
        let probeResult = await probeServer(port: defaultServerPort)
        let runs = await store.listRuns(limit: 1)
        let status = StatusResponse(
            storagePath: LogRollerPaths.defaultStorageRoot().path(percentEncoded: false),
            hasRuns: !runs.isEmpty,
            serverPort: defaultServerPort,
            serverActive: probeResult.isActive,
            activeBaseURL: probeResult.baseURL,
            healthURL: probeResult.healthURL,
            healthStatusCode: probeResult.statusCode,
            serverError: probeResult.error
        )

        do {
            let data = try LogRollerJSONCoders.encoder.encode(status)
            if let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        } catch {
            fputs("Failed to encode status output\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func probeServer(port: UInt16) async -> ServerProbeResult {
        let delegate = LocalTLSTrustDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 1.5
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var firstError: String?
        for baseURL in probeBaseURLs(port: port) {
            guard let url = URL(string: "\(baseURL)/healthz") else {
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    if firstError == nil {
                        firstError = "Received non-HTTP response from \(url.absoluteString)."
                    }
                    continue
                }

                guard httpResponse.statusCode == 200 else {
                    if firstError == nil {
                        firstError = "Health check returned HTTP \(httpResponse.statusCode) at \(url.absoluteString)."
                    }
                    continue
                }

                if let payload = try? LogRollerJSONCoders.decoder.decode(HealthPayload.self, from: data),
                   payload.ok {
                    return ServerProbeResult(
                        isActive: true,
                        baseURL: baseURL,
                        healthURL: url.absoluteString,
                        statusCode: httpResponse.statusCode,
                        error: nil
                    )
                }

                if firstError == nil {
                    firstError = "Health check did not return expected payload at \(url.absoluteString)."
                }
            } catch {
                if firstError == nil {
                    firstError = "Unable to reach \(url.absoluteString): \(error.localizedDescription)"
                }
            }
        }

        return ServerProbeResult(
            isActive: false,
            baseURL: nil,
            healthURL: nil,
            statusCode: nil,
            error: firstError ?? "No reachable LogRoller HTTPS health endpoint found."
        )
    }

    private static func probeBaseURLs(port: UInt16) -> [String] {
        var seen: Set<String> = []
        let preferredLocalBaseURLs = [
            "https://localhost:\(port)",
            "https://127.0.0.1:\(port)",
            "https://[::1]:\(port)",
        ]

        return (preferredLocalBaseURLs + LogRollerNetwork.ingestBaseURLs(port: port)).filter { baseURL in
            seen.insert(baseURL).inserted
        }
    }

    private static func printEvents(arguments: [String]) async {
        if arguments.contains("--help") {
            printUsage()
            return
        }

        let options: EventsOptions
        do {
            options = try parseEventsOptions(arguments)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            printUsage()
            Foundation.exit(1)
        }

        let store = makeStoreOrExit()
        let runID: String

        if let explicitRunID = options.runID {
            runID = explicitRunID
        } else {
            let latestRun = await store.listRuns(limit: 1).first
            guard let latestRun else {
                fputs("No runs found in local storage.\n", stderr)
                Foundation.exit(1)
            }
            runID = latestRun.runID
        }

        let events: [StoredEvent]
        do {
            events = try await store.events(runID: runID, deviceID: options.deviceID, limit: options.limit)
        } catch {
            fputs("Failed to read events: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }

        if options.useNDJSON {
            for event in events {
                do {
                    let data = try LogRollerJSONCoders.encoder.encode(event)
                    if let line = String(data: data, encoding: .utf8) {
                        print(line)
                    }
                } catch {
                    fputs("Failed to encode event row: \(error.localizedDescription)\n", stderr)
                    Foundation.exit(1)
                }
            }
            return
        }

        let response = EventsResponse(
            runID: runID,
            deviceID: options.deviceID,
            count: events.count,
            events: events
        )

        do {
            let data = try LogRollerJSONCoders.encoder.encode(response)
            if let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        } catch {
            fputs("Failed to encode events output: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func printIngestHelp(arguments: [String]) {
        let options: IngestHelpOptions
        do {
            options = try parseIngestHelpOptions(arguments)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            printUsage()
            Foundation.exit(1)
        }

        let candidateBaseURLs = LogRollerNetwork.ingestBaseURLs(port: defaultServerPort)
        let baseURL = candidateBaseURLs.first ?? "https://localhost:\(defaultServerPort)"
        let curlBatchExample = """
        curl --cacert "$HOME/Library/Application Support/mkcert/rootCA.pem" \\
          -H "Content-Type: application/json" \\
          -X POST "\(baseURL)/ingest" \\
          -d '{"run_id":"run_2026-02-19_manual","device_id":"iphone15pro_01","events":[{"ts":"2026-02-19T20:15:01.123Z","level":"info","event":"rtc.connected","seq":184,"payload":{"peer":"B","latency_ms":42}}]}'
        """

        let curlSingleEventExample = """
        curl --cacert "$HOME/Library/Application Support/mkcert/rootCA.pem" \\
          -H "Content-Type: application/json" \\
          -X POST "\(baseURL)/ingest" \\
          -d '{"ts":"2026-02-19T20:15:01.123Z","level":"error","event":"rtc.failed","run_id":"run_2026-02-19_manual","device_id":"iphone15pro_01","payload":{"reason":"timeout"}}'
        """

        switch options.outputFormat {
        case .markdown:
            print("""
            # LogRoller Ingest Quickstart

            Base URL: `\(baseURL)`

            Candidate local URLs:
            - \(candidateBaseURLs.map { "`\($0)`" }.joined(separator: "\n- "))

            ## Endpoint
            - Method: `POST`
            - Path: `/ingest`
            - Content-Type: `application/json`
            - Accepts either:
              - A single event object
              - A batch object with `run_id`, `device_id`, and `events: [...]`

            ## Required Event Fields
            - `ts` (ISO-8601 UTC timestamp string)
            - `level` (`debug` | `info` | `warn` | `error`)
            - `event` (stable event name)
            - `payload` (JSON object; can be `{}`)

            ## Optional Event Fields
            - `run_id` (string)
            - `device_id` (string)
            - `seq` (integer)
            - `app` (object)
            - `context` (object)

            ## Fallback Behavior
            - If `run_id` is omitted, LogRoller auto-generates one.
            - If `device_id` is omitted, LogRoller uses `unknown_device`.

            ## Success Response
            `{"ok":true,"stored":<n>,"run_id":"...","device_id":"..."}`

            ## Health Check
            - Method: `GET`
            - Path: `/healthz`

            ## cURL (Batch)
            ```bash
            \(curlBatchExample)
            ```

            ## cURL (Single Event)
            ```bash
            \(curlSingleEventExample)
            ```

            ## Verify Ingested Events
            ```bash
            logroller events --run <run_id> --device <device_id> --limit 50
            ```
            """)
        case .json:
            let response = IngestHelpResponse(
                baseURL: baseURL,
                candidateBaseURLs: candidateBaseURLs,
                defaultPort: defaultServerPort,
                endpoint: "/ingest",
                method: "POST",
                contentType: "application/json",
                accepts: ["single_event", "batch"],
                requiredEventFields: [
                    .init(name: "ts", type: "string(ISO-8601 UTC)", description: "Client event timestamp."),
                    .init(name: "level", type: "string", description: "One of debug/info/warn/error."),
                    .init(name: "event", type: "string", description: "Stable event name."),
                    .init(name: "payload", type: "object", description: "Arbitrary JSON object.")
                ],
                optionalEventFields: [
                    .init(name: "run_id", type: "string", description: "Run/session identifier."),
                    .init(name: "device_id", type: "string", description: "Stable device identifier."),
                    .init(name: "seq", type: "integer", description: "Monotonic per-device sequence."),
                    .init(name: "app", type: "object", description: "App metadata."),
                    .init(name: "context", type: "object", description: "Environment/context metadata.")
                ],
                fieldFallbacks: [
                    "run_id: auto-generated when omitted",
                    "device_id: uses unknown_device when omitted"
                ],
                responseShape: #"{"ok":true,"stored":<n>,"run_id":"...","device_id":"..."}"#,
                healthEndpoint: "/healthz",
                curlBatchExample: curlBatchExample,
                curlSingleEventExample: curlSingleEventExample,
                notes: [
                    "Use the mkcert root CA with curl --cacert for local TLS.",
                    "The endpoint also accepts a single event object directly.",
                    "Verify delivery with logroller events --run <run_id> --device <device_id>."
                ]
            )

            do {
                let data = try LogRollerJSONCoders.encoder.encode(response)
                if let string = String(data: data, encoding: .utf8) {
                    print(string)
                }
            } catch {
                fputs("Failed to encode ingest-help output: \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
        }
    }

    private static func parseEventsOptions(_ arguments: [String]) throws -> EventsOptions {
        var options = EventsOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--run":
                let value = try value(after: argument, in: arguments, at: index)
                options.runID = value
                index += 2
            case "--device":
                let value = try value(after: argument, in: arguments, at: index)
                options.deviceID = value
                index += 2
            case "--limit":
                let value = try value(after: argument, in: arguments, at: index)
                guard let limit = Int(value), limit > 0 else {
                    throw CLIError.invalidOption("Invalid value for --limit: \(value)")
                }
                options.limit = limit
                index += 2
            case "--ndjson":
                options.useNDJSON = true
                index += 1
            case "--json":
                options.useNDJSON = false
                index += 1
            default:
                throw CLIError.invalidOption("Unknown option: \(argument)")
            }
        }

        return options
    }

    private static func parseIngestHelpOptions(_ arguments: [String]) throws -> IngestHelpOptions {
        var options = IngestHelpOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help":
                printUsage()
                Foundation.exit(0)
            case "--json":
                options.outputFormat = .json
                index += 1
            case "--markdown":
                options.outputFormat = .markdown
                index += 1
            default:
                throw CLIError.invalidOption("Unknown option: \(argument)")
            }
        }

        return options
    }

    private static func value(after option: String, in arguments: [String], at index: Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw CLIError.invalidOption("Missing value for \(option)")
        }
        let value = arguments[valueIndex]
        guard !value.hasPrefix("--") else {
            throw CLIError.invalidOption("Missing value for \(option)")
        }
        return value
    }

    private static func makeStoreOrExit() -> NDJSONEventStore {
        do {
            return try NDJSONEventStore(rootDirectory: LogRollerPaths.defaultStorageRoot())
        } catch {
            fputs("Failed to initialize storage: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private enum CLIError: LocalizedError {
        case invalidOption(String)

        var errorDescription: String? {
            switch self {
            case let .invalidOption(message):
                return message
            }
        }
    }

    private static func printUsage() {
        print("""
        Usage:
          logroller status
          logroller events [--run <run_id>] [--device <device_id>] [--limit <n>] [--json|--ndjson]
          logroller ingest-help [--markdown|--json]

        Notes:
          - If --run is omitted, the latest run is used.
          - Output defaults to JSON; use --ndjson for one-event-per-line output.
          - ingest-help defaults to Markdown output.
        """)
    }
}
