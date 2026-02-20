# PROJECT.md — LogRoller (macOS)

## One-liner
A macOS desktop app that runs a local HTTPS “log sink” server to collect test logs from PWAs/iPhones on the LAN, provides a UI to browse/manage the collected data, and exposes a CLI designed for AI agent (“Skill”) integration.

---

## Goals
1. **Local HTTPS Ingest Server**
   - Listen on a configurable port (default: 8443).
   - Accept data from any client on the LAN (no auth for v1).
   - Store received payloads locally, organized by device + run/session.
   - Be robust to bursts, duplicates, and partial failures.

2. **Desktop UI (macOS)**
   - Show incoming events live (tail view).
   - Browse by Run → Device → Timeline.
   - Search/filter (level, event type, time range, run_id, device_id).
   - Maintenance actions: delete runs, clear older than N days, export runs.

3. **CLI for Agent/Skill Integration**
   - Query latest runs, summarize errors, export, and stream tail output.
   - Outputs machine-readable formats (JSON/NDJSON) by default.
   - Stable command surface intended for LLM tools/agents.

4. **HTTPS Trust UX**
   - Default to HTTPS.
   - Provide a practical workflow for trusting certs on iPhones/laptops during local testing.

---

## Non-Goals (v1)
- Strong authentication, multi-user security model, Internet exposure.
- Cloud sync, remote access outside LAN.
- Complex visualization dashboards (basic list + filters only).
- Fully automated iOS trust installation (we can guide the user, but keep it simple).

---

## Primary Use Case
You are testing a PWA on multiple iPhones. The PWA is configured so that each phone sends structured logs to your Mac on the same Wi-Fi. The Mac app collects logs, lets you inspect runs, and provides a CLI so an AI agent (Codex) can analyze the latest test run and identify failures, anomalies, or protocol divergences.

---

## Product Requirements

### Ingest API (HTTP)
**Base URL:** `https://<mac-host>:8443`

#### Endpoints
- `POST /ingest`
  - Body: JSON with a batch of events (preferred), or single event.
  - Response: 200 with `{ "ok": true, "stored": <n>, "run_id": "...", "device_id": "..." }`
  - Accepts `Content-Type: application/json`

- `GET /healthz`
  - Returns `{ "ok": true, "version": "...", "uptime_s": ... }`

- `GET /runs` (optional for v1 if CLI uses local DB directly)
- `GET /runs/:run_id/devices`
- `GET /runs/:run_id/devices/:device_id/events` (paged)

> Note: For v1, the UI and CLI can read directly from the local storage/DB and the HTTP API can remain ingest-only.

#### Event Format (canonical)
Each event is a JSON object with at least:

```json
{
  "ts": "2026-02-18T20:15:01.123Z",
  "level": "info",
  "event": "rtc.connected",
  "run_id": "run_2026-02-18T20-14-22Z_abcd",
  "device_id": "iphone15pro_01",
  "seq": 184,
  "payload": { "peer": "B", "latency_ms": 42 }
}
```

#### Fields
- `ts` (string, ISO-8601 UTC): event timestamp (client)
- `recv_ts` (string, ISO-8601 UTC): server receive timestamp (server adds)
- `level` (string): `debug|info|warn|error`
- `event` (string): stable event name
- `run_id` (string): groups all devices for a test run (client provided; server can generate fallback)
- `device_id` (string): stable identifier per device
- `seq` (int): monotonically increasing per device per run (helps ordering/dup detection)
- `payload` (object): arbitrary JSON object
- `app` (optional): `{ name, version, build, env }`
- `context` (optional): `{ url, visibility, userAgent }`

#### Batch Format
`POST /ingest` can also accept:

```json
{
  "run_id": "run_...",
  "device_id": "iphone...",
  "events": [ { ... }, { ... } ]
}
```

Server should normalize into per-event rows internally.

### Storage

#### Requirements
- Efficient appending and querying.
- Able to export a run as NDJSON for offline analysis.
- Able to delete by run or by retention policy.

#### Proposed Storage Approach (v1)
- SQLite for metadata + event index
- Tables: `runs`, `devices`, `events`
- Optional: store full payload JSON as `TEXT` (or `BLOB`) in `events.payload_json`
- Optional: also write NDJSON files to disk per run/device for easy tailing/export:
  `~/Library/Application Support/LanLogSink/runs/<run_id>/<device_id>.ndjson`

#### SQLite Schema (suggested)
```sql
runs(run_id TEXT PRIMARY KEY, created_ts TEXT, label TEXT NULL)
devices(id INTEGER PK, run_id TEXT, device_id TEXT, first_seen_ts TEXT, last_seen_ts TEXT)
events(id INTEGER PK, run_id TEXT, device_id TEXT, seq INTEGER, ts TEXT, recv_ts TEXT, level TEXT, event TEXT, payload_json TEXT)
```

Indexes:

```sql
events(run_id, device_id, seq)
events(run_id, ts)
events(level)
events(event)
```

### macOS App UI (SwiftUI)

#### Screens
- **Runs**
  - List runs, creation time, device count, event count, errors count.
  - Actions: delete run, export run (NDJSON/ZIP), label run.
- **Devices in Run**
  - Show devices, last seen, error counts.
- **Timeline**
  - Virtualized list of events, with filters.
  - Toggle “live tail” (auto-scroll).
- **Settings**
  - Port, bind address (default `0.0.0.0`), storage location, retention days.
  - Certificate mode: “mkcert CA”, “self-signed”, “import custom cert”.

#### UX Notes
- Must remain responsive while ingesting.
- Use background queue for DB writes.
- Live view should subscribe to new events via in-app publisher (not polling DB).

#### App Lifecycle UX
- Dismissing/closing the main desktop window must NOT stop the HTTPS ingest server.
- On first window close attempt, show a warning that the app will keep running in the background and continue ingesting.
- Warning dialog includes a checkbox like “Don’t show this again,” persisted in app preferences.
- The app remains accessible via macOS app switching/Dock, and users can fully stop it with `Command-Q` or Quit from the app menu.

### CLI (`logroller`)

#### Requirements
- Non-interactive, stable outputs.
- Default output should be JSON or NDJSON for agent parsing.
- Provide “human” output with `--pretty` or `--table`.

#### Proposed Commands
```bash
logroller status
logroller runs list [--limit N] [--json]
logroller runs latest [--json]
logroller runs export <run_id> --format ndjson --out <path>
logroller runs delete <run_id>
logroller events tail --run <run_id> [--device <device_id>] [--level error] [--ndjson]
logroller events query --run <run_id> --since "10m" --event "rtc.*" --json
logroller summarize <run_id> --json
```

- `logroller status`: prints server status, port, storage path.
- `logroller summarize <run_id> --json`: produces error counts, top events, gaps, out-of-order seq, missing phases.

#### Skill-Friendly Outputs
`summarize` should return a structured JSON object with:
`run_id`, `devices`, `error_events`, `warnings`, `anomalies`, `time_bounds`, `counts_by_event`.

### HTTPS Certificates / Trust Strategy

#### Modes

I have generated a Local dev CA via mkcert, and have transferred the PEM file to iPhones already.
It is installed and trusted on the devices.

/Users/dav/Library/Application Support/mkcert/rootCA.pem


#### Requirements for v1
The app must be able to:
- Detect if mkcert is installed.
- If not installed, show instructions or offer to proceed with self-signed.
- Serve a help page describing iOS trust steps.
- Do NOT attempt to bypass Apple security restrictions.

### Networking Constraints / Assumptions
- Devices are on same LAN/Wi-Fi.
- The Mac must bind to `0.0.0.0` to be reachable by iPhones.
- If macOS firewall blocks incoming connections, app should detect and warn.

### Architecture (suggested)
Single Xcode workspace with:
- `LogRollerCore` (Swift package): models, validation, storage (SQLite), export, summarize
- `LogRollerServer` (Swift package): HTTPS server, routing, request parsing, ingest pipeline
- `LogRollerApp` (macOS SwiftUI app): UI + embeds server + uses core storage
- `logroller` (Swift CLI): uses `LogRollerCore` to query storage and output JSON/NDJSON
  - Optional: talks to local app via IPC or reads DB directly

- Please consult AGENTS-swift.md for Swift coding guidelines

### Embedding the Server
- Server runs in-process within the macOS app.
- Launch at app start; stop only on full app quit.
- Closing/dismissing app windows must not stop the server process.
- Provide menu bar status and quick “copy URL” actions.

### Implementation Notes (Codex guidance)

#### Swift HTTPS Server Options
Pick one:
- Vapor (SwiftNIO) embedded in app (fast dev, good routing, TLS support).
- SwiftNIO HTTP + TLS (more work, more control).
- `Network.framework` is great for sockets but less turnkey for HTTP/TLS routing.

Recommendation: Vapor for speed and reliability.

#### SQLite
- Use SQLite.swift or GRDB.
- Recommendation: GRDB (strong, mature, good Swift ergonomics).

#### Concurrency
- Ingest path should enqueue events onto a writer queue to avoid blocking requests.
- Backpressure: cap in-memory queue; if exceeded, respond 503 and record drop counts.

#### Validation
- Ensure required fields exist; add server-side defaults (`recv_ts`).
- Normalize `run_id` and `device_id` strings (trim, length limits).

#### Dedup / Ordering
- Optional v1: detect duplicates by (`run_id`, `device_id`, `seq`) unique constraint.
- If `seq` missing, allow duplicates.

### Acceptance Criteria (Definition of Done)
- iPhone PWA can `POST /ingest` successfully over HTTPS on LAN.
- Events are persisted and visible in UI within 1 second of receipt.

UI can:
- list runs
- view per-device timelines
- filter to errors only
- delete a run
- export a run as NDJSON
- close/dismiss the main window while ingest continues in the background
- show a close-window warning with a persisted “don’t show again” option

CLI can:
- list runs
- export latest run
- summarize a run in JSON

Certificate workflow:
- mkcert path works on macOS
- app provides a clear iOS trust guide page (and ideally a downloadable CA/profile)

### Milestones
- **M1 — Core ingest + storage**
  - Implement `/healthz`, `/ingest`
  - SQLite schema + writer
  - Basic NDJSON export
- **M2 — macOS UI**
  - Runs list, timeline view, delete/export
- **M3 — CLI**
  - runs list/latest/export/delete
  - summarize JSON
- **M4 — HTTPS trust UX**
  - mkcert integration + CA/profile distribution help page

### Developer Experience / Testing
- Provide a sample client script:

```bash
curl -k https://localhost:8443/ingest ...
```

- Provide a sample PWA snippet to batch-send logs.
- Unit tests for:
  - event validation
  - SQLite insert/query
  - summary/anomaly detection

### Open Questions (OK to decide during implementation)
- DB location: default App Support vs user-selectable folder.
- Whether CLI reads DB directly or talks to app via local socket.
- Whether export includes raw request bodies (for debugging).

### Deliverables
- Xcode project/workspace
- macOS app bundle
- `logroller` binary
- README with:
  - how to run server
  - how to trust certs on iOS
  - example PWA logging snippet

This PROJECT.md kept updated as requirements evolve.
