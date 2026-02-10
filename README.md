# db-mcp

A self-contained MCP server for PostgreSQL database access via stdio, with credential management through 1Password.

## Requirements

- Elixir 1.18+ (uses built-in `JSON` module)
- [1Password CLI](https://developer.1password.com/docs/cli/) (`op`) for credential lookup
- Docker (for database tests only)

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

The server exposes 6 tools over MCP:

| Tool | Description |
|------|-------------|
| `pg_connect` | Connect to a database using 1Password vault credentials |
| `pg_disconnect` | Close a connection (or all connections) |
| `pg_status` | Show connection info (host, database, user, version, pool health) |
| `pg_query` | Execute a read-only SQL query (table/json/csv output) |
| `pg_submit_write` | Submit a write query for two-step confirmation |
| `pg_execute_write` | Execute a previously submitted write query by ID |

### Connection flow

1. `pg_connect` prompts for 1Password biometric once, then the connection persists for the session
2. Multiple simultaneous named connections are supported (e.g. `prod`, `staging`)
3. Read queries run in a `READ ONLY` transaction
4. Write queries require explicit two-step confirmation: submit, then execute

## Testing

The test harness is a single `test.exs` file with three progressive layers:

```bash
make test              # All tests (unit + integration + database)
make test.unit         # Unit tests only — no external dependencies
make test.integration  # Unit + integration — starts server as a Port child process
make test.database     # Unit + database — requires Docker
```

Or run directly:

```bash
elixir test.exs                            # Unit tests only
elixir test.exs --integration              # + integration tests
elixir test.exs --database                 # + database tests
elixir test.exs --integration --database   # All 79 tests
```

### Layer 1: Unit tests (always run)

Tests module internals with no external dependencies:

- **DbMcp.SQL** — read-only validation, comment stripping, keyword blocking
- **DbMcp.Format** — table/json/csv formatting, type decoding (nil, bool, Date, DateTime, Decimal, jsonb, list), row limits, cell truncation, response size cap, CSV escaping
- **DbMcp.Credentials** — 1Password JSON parsing, field label variants, port defaults, validation
- **DbMcp.Writes** — GenServer submit/fetch round-trip, one-time consumption, purge

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
- **Write Flow** — submit, fetch, execute, verify with SELECT
- **jsonb Handling** — jsonb columns render as formatted JSON strings

## Architecture

The entire server is a single `server.exs` file — no Mix project. Modules defined within:

- `DbMcp.Log` — stderr logging
- `DbMcp.Credentials` — 1Password CLI integration and field parsing
- `DbMcp.SQL` — read-only query validation
- `DbMcp.Writes` — ETS-backed pending write queue with TTL
- `DbMcp.Format` — query result formatting (table, json, csv)
- `DbMcp.Connection` — GenServer managing named Postgrex connection pools
- `DbMcp.Tools` — MCP tool definitions and dispatch
- `DbMcp.Server` — JSON-RPC 2.0 stdio loop and MCP protocol handling
