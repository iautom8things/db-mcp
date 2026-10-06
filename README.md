# db-mcp

[![CI](https://github.com/autom8things/db-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/autom8things/db-mcp/actions/workflows/ci.yml)

A self-contained MCP server that gives Claude (or any MCP client) read/write access to PostgreSQL databases over stdio, with credentials sourced from 1Password and a browser-based approval flow for any non-read query. Reach for it when you want an AI assistant to *safely* explore a real database — read queries run in a `READ ONLY` transaction, writes require an explicit human click in a local web UI before they execute, and an interactive `psql` terminal is mounted in the browser so you can watch what is happening and run ad-hoc SQL alongside the agent.

If you just need a query tool without guardrails, use `psql` directly; if you need a generic MCP shim, use a thinner alternative. `db-mcp` is opinionated specifically about *AI-driven* database work.

## Requirements

- Elixir 1.18+ (uses built-in `JSON` module)
- Python 3 — required at runtime by `pg_connect` / `pg_connect_local`. `server.exs` spawns `pty_bridge.py` as a port executable to host an interactive `psql` PTY for the optional web terminal. Missing Python will surface as a silently broken `pg_connect` flow.
- [1Password CLI](https://developer.1password.com/docs/cli/) (`op`) for credential lookup — only required for `pg_connect`. `pg_connect_local` does not call `op`.
- Docker (for database tests only)

A [`.tool-versions`](.tool-versions) file pins the exact Erlang/Elixir/Python the project is developed and shipped on (Erlang 28, Elixir 1.19, Python 3.13). If you use [asdf](https://asdf-vm.com/) or [mise](https://mise.jdx.dev/), run `asdf install` (or `mise install`) in the repo root to match it. CI also tests the documented Elixir 1.18 floor, so older toolchains within the stated range remain supported.

## Quickstart

The fastest path from zero to a query running against a local Postgres, with no 1Password required:

```bash
git clone https://github.com/autom8things/db-mcp "$HOME/db-mcp" && cd "$HOME/db-mcp"
make install                                       # warm Mix.install deps so first boot is fast
elixir server.exs                                  # boots the MCP server; logs Web UI URL to stderr
# In your MCP client (e.g. Claude Code), point "db" at "$HOME/db-mcp/server.exs" (see Usage below),
# then call pg_connect_local { "port": 5432, "username": "postgres", "password": "postgres", "database": "postgres" }
```

After `pg_connect_local` returns, you can run `pg_query { "sql": "SELECT now()" }` from the same MCP client and watch the same session in the browser psql terminal at the Web UI URL printed on stderr. No `op` biometric prompt, no 1Password vault setup — just a localhost Postgres of your choosing.

## Development

Three commands to go from a fresh clone to an iterating contributor:

```bash
git clone https://github.com/autom8things/db-mcp "$HOME/db-mcp" && cd "$HOME/db-mcp"
make install                                       # warm Mix.install deps (~30s once, cached after)
make test.unit                                     # fast unit suite — no Docker, no Postgres, no network
```

From there:

- `make run` — start `server.exs` in the foreground for a manual smoke test against a real MCP client.
- `make check` — composite target (format-check + lint + unit tests) suitable for pre-commit and CI.
- `make test.integration` — adds the stdio-handshake integration suite (no Docker).
- `make test.database` — spins a throwaway Docker Postgres and exercises the full read/write/approval flow.
- `make clean` — clears the warm `Mix.install` cache when deps change.

If you don't have Elixir 1.18+ installed yet, the two common paths are `asdf install elixir 1.18.0` (with the asdf-elixir plugin) or `brew install elixir` on macOS.

## Usage

Add to your MCP client configuration (e.g. Claude Code `~/.claude/settings.json`):

```json
{
  "mcpServers": {
    "db": {
      "command": "elixir",
      "args": ["/path/to/db-mcp/server.exs"]
    }
  }
}
```

The server exposes 8 tools over MCP:

| Tool | Description |
|------|-------------|
| `pg_connect` | Connect to a database using credentials from a 1Password item |
| `pg_connect_local` | Connect to a localhost database with explicit credentials (no 1Password) |
| `pg_disconnect` | Close a connection (or all connections) |
| `pg_status` | Show connection info (host, database, user, version, pool health) |
| `pg_query` | Execute a read-only SQL query (table/json/csv output) |
| `pg_submit_write` | Submit a write query with `description`/`reason`/`impact` context; blocks until the user approves or rejects in the web UI, then executes |
| `session_history` | Read recent output from the browser psql terminal scrollback |
| `search_history` | Search the browser psql terminal scrollback for a term |

### Connection flow

1. `pg_connect` prompts for 1Password biometric once, then the connection persists for the session
2. Multiple simultaneous named connections are supported (e.g. `prod`, `staging`)
3. Read queries run in a `READ ONLY` transaction
4. Write queries require explicit two-step confirmation: submit, then human approval in the browser

## Configuration

### Server environment variables

All are optional; defaults preserve the out-of-the-box behavior.

| Variable             | Purpose                                          | Default                                                  | Example                                  |
|----------------------|--------------------------------------------------|----------------------------------------------------------|------------------------------------------|
| `DB_MCP_WEB_PORT`    | Pin the web approval UI to a fixed TCP port      | random free port (OS-assigned on each boot)              | `DB_MCP_WEB_PORT=54321`                  |
| `DB_MCP_OP_BIN`      | Path to the 1Password CLI used by `pg_connect`   | `op` (resolved via `PATH`)                               | `DB_MCP_OP_BIN=/opt/homebrew/bin/op`     |
| `DB_MCP_OP_ACCOUNT`  | 1Password account passed to `op item get` as `--account`. Overridden per-call by the `account` parameter on `pg_connect`. When neither is set, `--account` is omitted and `op` uses its currently signed-in account | unset (use `op`'s default account)                       | `DB_MCP_OP_ACCOUNT=my-team`              |
| `DB_MCP_PYTHON_BIN`  | Path to the `python3` interpreter for the PTY bridge | `System.find_executable("python3")` (resolved via `PATH`) | `DB_MCP_PYTHON_BIN=/Users/me/.venv/bin/python3` |
| `DB_MCP_AUTO_OPEN`   | Set to `0`/`false`/`no` to stop the server from opening the web UI in a browser while a write approval is blocked waiting on a human | enabled | `DB_MCP_AUTO_OPEN=0`                     |

Set them in your MCP client config (e.g. Claude Code `~/.claude/settings.json`) under the server's `env` block, or export them in the parent shell. An invalid `DB_MCP_WEB_PORT` value (non-integer or out of range) falls back to random allocation with a warning on stderr.

If you have more than one 1Password account signed in, set `DB_MCP_OP_ACCOUNT` so `pg_connect` targets the right one. In a Claude Code MCP config that looks like:

```json
{
  "mcpServers": {
    "db": {
      "command": "elixir",
      "args": ["/path/to/db-mcp/server.exs"],
      "env": {
        "DB_MCP_OP_ACCOUNT": "my-team"
      }
    }
  }
}
```

Or in the parent shell: `export DB_MCP_OP_ACCOUNT=my-team`. Run `op account list` to see your signed-in account shorthands.

Agents can also pick the account per connection by passing `account` directly to `pg_connect` (shorthand, sign-in address, or account UUID — anything `op --account` accepts):

```json
{ "vault_id": "abc123", "item_name": "prod-readonly", "account": "my-team" }
```

The `account` parameter takes precedence over `DB_MCP_OP_ACCOUNT`; when both are absent, `op` uses its currently signed-in account.

### 1Password item schema (for `pg_connect`)

`pg_connect` looks up a 1Password item by `vault_id` and `item_name` via the `op` CLI and reads the database credentials from its fields. By default no `--account` flag is passed, so `op` uses its currently signed-in account; pass the `account` parameter on `pg_connect` or set `DB_MCP_OP_ACCOUNT` to target a specific account (see [Server environment variables](#server-environment-variables) above). Field labels are matched case-insensitively, and several common label variants are accepted (see `server.exs:39-50`):

| Connection setting | Accepted field labels      | Required | Default |
|--------------------|----------------------------|----------|---------|
| Host               | `host`, `hostname`, `server` | yes      | —       |
| Port               | `port`                     | no       | `5432`  |
| Username           | `username`, `user`         | yes      | —       |
| Password           | `password`                 | yes      | —       |
| Database           | `database`, `dbname`, `db` | yes      | —       |

Example 1Password item (Database type works well, but any item type with these field labels will do):

```
Title:    prod-readonly
Vault:    Engineering
Fields:
  host       db.prod.internal.example.com
  port       5432
  username   readonly_app
  password   ••••••••••••••
  database   app_production
```

Then from an MCP client:

```jsonc
// tool: pg_connect
{
  "vault_id": "abcd1234efgh5678",       // 1Password vault ID, not name
  "item_name": "prod-readonly",
  "name": "prod"                          // optional; defaults to the database name
}
```

To find a vault ID: `op vault list`.

### Local dev databases (no 1Password)

For local-only databases where 1Password is overkill, use `pg_connect_local`. The host is hard-coded to `localhost`, so this path cannot reach remote hosts:

```jsonc
// tool: pg_connect_local
{
  "port": 5432,
  "username": "postgres",
  "password": "postgres",
  "database": "myapp_dev",
  "name": "dev"                           // optional; defaults to the database name
}
```

Use this for Docker Compose-managed dev databases, `make db.up` style local setups, or one-off scratch databases. For any remote database, use `pg_connect` with a 1Password item instead.

## Web approval UI

On startup, `server.exs` allocates a random free TCP port (by listening on port `0` and capturing the OS-assigned port — see `server.exs:2059-2063`) and starts a Bandit HTTP server on it. Two different sessions of `db-mcp` therefore won't collide. The chosen URL is logged to stderr on boot:

```
[INFO] Starting db-mcp v0.1.0
[INFO] Web UI: http://localhost:54321
```

The same URL is also embedded in the responses from `pg_connect`, `pg_connect_local`, `pg_status`, and `pg_submit_write`, and is exposed in the MCP `initialize` response as `serverInfo.webUi`, so MCP clients can surface it directly to the user.

The server binds `127.0.0.1` only. The page carries an unauthenticated `psql` terminal, so it must never be reachable from the network.

What you see in the browser:

- **Interactive psql terminal** — a real `psql` session running inside a PTY (via `pty_bridge.py`), mirrored over a WebSocket. You can run any SQL here directly; it doesn't go through the approval flow, because the human is already at the keyboard.
- **Pending write approval banner** — when an MCP client calls `pg_submit_write`, a card appears with the SQL (pretty-printed and syntax-highlighted), the connection name, and the agent's context: **What** the query does, **Why** the agent wants to run it, and its expected **Impact** (rows affected / reversibility). Buttons: **Approve** (runs the query and returns the result to the MCP client) or **Reject** (the query is never executed and the MCP client gets back a rejection message).
- **Connection status** — host, database, user, port for the currently attached connection.
- **Agent activity pane** — a running log of `pg_query`/`pg_submit_write` calls with highlighted SQL, the agent's description, and each result.

### Approval alerting

A blocked agent is useless if nobody notices it's blocked, so a pending approval escalates until a human responds:

- **Browser auto-open** — when `pg_submit_write` blocks and no web UI tab is connected, the server opens the UI in your default browser (`open` on macOS, `xdg-open` elsewhere). It re-checks every minute and re-opens if the tab was closed. Disable with `DB_MCP_AUTO_OPEN=0`.
- **Notification + ding** — an open tab fires a browser notification and an audio ding when the approval appears, and repeats both every minute while it stays unresolved. Clicking the notification focuses the tab. (Browsers require one interaction with the page before notification permission and audio can activate.)
- **Tab title flash** — the title alternates with `⚠️ APPROVAL NEEDED` so the pending state is visible from a background tab.

### Why two-step writes?

Read-only queries from an AI are low-stakes — at worst they're slow or noisy. Writes are different: a hallucinated `UPDATE` without a `WHERE` clause can wreck production. `db-mcp` splits the two by design:

- `pg_query` is gated by a `READ ONLY` transaction at the database level, so even if the SQL validator misses something, PostgreSQL will refuse to mutate.
- `pg_submit_write` is the only path to mutating SQL, and it *blocks* the MCP call until a human clicks Approve or Reject in the browser. There is no "auto-approve" mode, and there is no separate `pg_execute_write` tool the agent can call to bypass approval — submission and execution are fused inside a single approval-gated call.

This is deliberate friction. The agent cannot "forget" to ask, and the human always sees the exact SQL that's about to run.

## Testing

The test harness is a single `test.exs` file with three progressive layers:

```bash
make test              # All tests (unit + integration + database)
make test.unit         # Unit tests only — no external dependencies
make test.smoke        # Pre-push gate: unit + integration (no Docker)
make test.integration  # Unit + integration — starts server as a Port child process
make test.database     # Unit + database — requires Docker
```

### Pre-push gate: `make test.smoke`

`make test.smoke` is the recommended pre-push check. It runs the unit suite plus
the integration layer, which:

- Boots `server.exs` as a Port child and asserts `tools/list` returns the exact
  set of 8 documented tool names (catches a regression that silently drops
  `pg_connect_local` or `search_history`).
- Spawns `python3 pty_bridge.py` and exchanges one framed init/started/exited
  cycle for `command: "echo"` (catches a missing `pty_bridge.py` or a drift in
  the length-prefixed binary frame protocol).

Neither layer needs Docker or a running Postgres, so the smoke gate completes in
seconds.

Or run directly:

```bash
elixir test.exs                            # Unit tests only
elixir test.exs --integration              # + integration tests
elixir test.exs --database                 # + database tests
elixir test.exs --integration --database   # Full suite
```

### Layer 1: Unit tests (always run)

Tests module internals with no external dependencies:

- **DbMcp.SQL** — read-only validation, comment stripping, keyword blocking
- **DbMcp.Format** — table/json/csv formatting, type decoding (nil, bool, Date, DateTime, Decimal, jsonb, list), row limits, cell truncation, response size cap, CSV escaping
- **DbMcp.Credentials** — 1Password JSON parsing, field label variants, port defaults, validation
- **DbMcp.Approval** — blocking write-approval lifecycle, approval/rejection responses, concurrent submit guard

### Layer 2: Integration tests (`--integration`)

Starts `server.exs` as a child process via Erlang Port and communicates over stdio:

- **MCP Handshake** — initialize, notifications/initialized, tools/list, ping
- **Error Handling** — bad JSON (-32700), unknown method (-32601), unknown tool, missing params (-32602), invalid request (-32600)
- **Server Resilience** — survives bad JSON, unknown methods, and consecutive errors without crashing (validates the try/rescue fix)
- **Tool Calls (no DB)** — correct error responses when no database is connected

### Layer 3: Database tests (`--database`)

Spins up a throwaway Docker PostgreSQL, seeds test data, and bypasses 1Password by injecting a connection directly:

- **Connection Lifecycle** — status, status_all, list_connections
- **Read Queries** — SELECT across all types (text, int, bool, date, jsonb, NULL), LIMIT, format options
- **Read-Only Enforcement** — INSERT via pg_query fails gracefully (not crash)
- **Write Flow** — pg_submit_write blocks for approval, executes on approval, verifies with SELECT
- **jsonb Handling** — jsonb columns render as formatted JSON strings

## Architecture

The entire server is a single `server.exs` file — no Mix project. Modules defined within:

- `DbMcp.Log` — stderr logging
- `DbMcp.Credentials` — 1Password CLI integration and field parsing
- `DbMcp.SQL` — read-only query validation
- `DbMcp.Format` — query result formatting (table, json, csv)
- `DbMcp.Connection` — GenServer managing named Postgrex connection pools
- `DbMcp.Pty` — interactive psql PTY backed by `pty_bridge.py`
- `DbMcp.Approval` — blocking write-approval coordinator
- `DbMcp.Web` — Bandit/Plug HTTP server hosting the browser UI and approval API
- `DbMcp.Tools` — MCP tool definitions and dispatch
- `DbMcp.Server` — JSON-RPC 2.0 stdio loop and MCP protocol handling

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the release history. The project follows the [Keep a Changelog](https://keepachangelog.com/) format.

## License

MIT — see [LICENSE](LICENSE).
