---
name: logroller-client-integration
description: Integrate application clients to send structured events to a local LogRoller server. Use when asked to wire logging/telemetry to LogRoller, including run_id/device_id strategy, batching, retry behavior, and verification with the logroller CLI.
---

# LogRoller Client Integration

Use this skill when the user asks for things like:
- "implement having clients send events to local LogRoller"
- "wire telemetry/logging to LogRoller"
- "send app events to my local ingest server"

## Inputs To Confirm
- `LOGROLLER_BASE_URL` (example: `https://<mac-host>:8443`)
- `run_id` strategy (single value per test session)
- `device_id` strategy (stable per client/device)
- Environment constraints for TLS trust (mkcert CA path, simulator/device trust setup)

If the user does not provide these, choose practical defaults and state them.

## Contract Discovery
Run this first to get the canonical ingest contract:

```bash
logroller ingest-help --json
```

Use that output as source of truth for endpoint, required fields, optional fields, and examples.

## Required Event Shape
Each event must contain:
- `ts` (ISO-8601 UTC string)
- `level` (`debug|info|warn|error`)
- `event` (stable event name)
- `payload` (JSON object)

Recommended fields:
- `run_id` (same for all clients in a test run)
- `device_id` (stable identifier)
- `seq` (monotonic integer per device per run)
- `app`, `context` (metadata)

## Implementation Workflow
1. Add a LogRoller transport module in the client codebase.
2. Add config flags/env vars:
   - `LOGROLLER_ENABLED` (default false outside dev/test)
   - `LOGROLLER_BASE_URL`
   - `LOGROLLER_RUN_ID`
   - `LOGROLLER_DEVICE_ID`
3. Build a small event adapter that maps existing logs to LogRoller event JSON.
4. Batch events and `POST` to `/ingest` with `Content-Type: application/json`.
5. Use retries with backoff for transient failures, but do not crash the app if delivery fails.
6. Flush on app background/exit when feasible.
7. Keep integration behind a runtime toggle so production behavior is unchanged unless enabled.

## Delivery Rules
- Prefer batch payloads:

```json
{
  "run_id": "run_2026-02-19_manual",
  "device_id": "iphone15pro_01",
  "events": [
    {
      "ts": "2026-02-19T20:15:01.123Z",
      "level": "info",
      "event": "rtc.connected",
      "seq": 184,
      "payload": {"peer":"B","latency_ms":42}
    }
  ]
}
```

- If there is no run/device ID available, still send events; LogRoller can fallback-generate identifiers.

## URLSession Lifecycle on iOS / visionOS

> **Warning:** On platforms where the OS suspends apps (iOS, visionOS), `URLSession` instances can be **invalidated by the OS** during app suspension. If the flush timer fires after this, calling `session.data(for:)` on the invalidated session throws an ObjC `NSGenericException` ("Task created in a session that has been invalidated") which is **not catchable by Swift `do`/`catch`** — it causes a fatal crash.

When implementing the LogRoller transport on Apple platforms:

1. **Create sessions lazily** — do not create the `URLSession` in `configure()`. Instead, create it on-demand in a helper (e.g., `ensureSession()`) called at flush time.
2. **Recreate on failure** — in the `catch` block of `flush()`, `nil` out the session reference. The next flush will create a fresh session automatically.
3. **Do not call `invalidateAndCancel()`** — the shutdown path should cancel the flush timer and let the session be deallocated naturally. Calling `invalidateAndCancel()` introduces a race where a queued flush or emit can use the session after invalidation.

```swift
// Example pattern
private var session: URLSession?

private func ensureSession() -> URLSession {
    if let s = session { return s }
    let s = URLSession(configuration: .default)
    session = s
    return s
}

func flush() async {
    let s = ensureSession()
    do {
        let (_, _) = try await s.data(for: request)
    } catch {
        session = nil  // force recreation on next flush
    }
}
```

## Validation Checklist
1. Send a known test event from the client.
2. Verify CLI status and confirm the HTTPS server is actually reachable:

```bash
logroller status
```

   Treat this as a hard gate before querying events:
   - `server_active` must be `true`
   - If `server_active` is `false`, read `server_error` and stop to fix server availability first
   - Optional diagnostics: `active_base_url`, `health_url`, `health_status_code`

3. Verify events are present for that device:

```bash
logroller events --run <run_id> --device <device_id> --limit 50
```

4. If needed for parsing pipelines, use NDJSON:

```bash
logroller events --run <run_id> --device <device_id> --limit 50 --ndjson
```

## Done Criteria
- Client emits events to `POST /ingest` successfully.
- `run_id` and `device_id` are consistently populated (or documented fallback behavior is accepted).
- Retries/toggles are in place.
- Events are verifiably queryable with `logroller events`.
