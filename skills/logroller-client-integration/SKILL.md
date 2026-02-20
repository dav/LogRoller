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

## Validation Checklist
1. Send a known test event from the client.
2. Verify CLI status:

```bash
logroller status
```

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
