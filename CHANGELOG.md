# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

## [0.2.0] - 2026-07-12

### Added

- Browser auto-open while an approval is blocked: `pg_submit_write` opens the web UI in the default browser when no UI tab is connected, and re-checks every minute while the approval stays pending. Disable with `DB_MCP_AUTO_OPEN=0`.
- Web UI approval alerting: a browser notification and an audio ding fire when the approval banner appears and repeat every minute until resolved; the tab title flashes `⚠️ APPROVAL NEEDED` while pending.
- Richer approval context from the agent: `pg_submit_write` now requires `description` (what) and `reason` (why) and accepts an optional `impact` (rows affected / reversibility). The context is rendered as What/Why/Impact rows in the approval banner and attached to activity-pane events.
- SQL pretty-printing and syntax highlighting in the approval banner and the agent-activity pane (sql-formatter + highlight.js via CDN).

### Fixed

- The connection header in the web UI used `String.valueOf(...)` (a Java-ism, not JavaScript), which threw whenever a connection was active and prevented the approval banner from updating.

## [0.1.0] - 2026-05-10

### Added

- Initial release of the `db-mcp` MCP server.
- Eight MCP tools: `pg_connect`, `pg_connect_local`, `pg_disconnect`, `pg_status`, `pg_query`, `pg_submit_write`, `session_history`, and `search_history`.
- Read/write split: `pg_query` runs inside a `READ ONLY` transaction; mutating SQL must flow through `pg_submit_write`.
- Two-step write flow with blocking human approval — submit and execute are fused inside a single approval-gated MCP call (no separate `pg_execute_write` bypass).
- Browser-based approval UI served by an embedded Bandit HTTP server on a random free port, with the URL logged to stderr and exposed via the MCP `initialize` response.
- Interactive `psql` terminal in the browser, backed by a Python PTY sidecar (`pty_bridge.py`) and mirrored over a WebSocket.
- 1Password CLI integration via `pg_connect` for credential lookup, with case-insensitive field-label matching and several common label variants.
- `pg_connect_local` path for localhost-only databases that does not require 1Password.
- Multi-connection support with named connections (e.g. `prod`, `staging`).
- Three-layer test harness (`test.unit`, `test.integration`, `test.database`) covering SQL validation, formatting, credentials, write queue, MCP handshake, error handling, and a full Dockerized Postgres round-trip.
