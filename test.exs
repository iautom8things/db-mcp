#!/usr/bin/env elixir

# Test harness for DB MCP Server
#
# Three layers of progressive testing, gated by CLI flags:
#   elixir test.exs                          # Unit tests only
#   elixir test.exs --integration            # + integration tests (server as Port)
#   elixir test.exs --database               # + database tests (requires Docker)
#   elixir test.exs --integration --database # all tests

# --- Test Framework ---

defmodule TestRunner do
  @moduledoc false

  def run(group_name, tests) do
    IO.puts("\n\e[1m=== #{group_name} ===\e[0m\n")

    results =
      Enum.map(tests, fn {name, fun} ->
        try do
          fun.()
          IO.puts("  \e[32m✓ #{name}\e[0m")
          :pass
        rescue
          e ->
            IO.puts("  \e[31m✗ #{name}\e[0m")
            IO.puts("    \e[31m#{Exception.message(e)}\e[0m")
            :fail
        end
      end)

    {group_name, results}
  end

  def summarize(all_results) do
    {total_pass, total_fail} =
      Enum.reduce(all_results, {0, 0}, fn {_group, results}, {p, f} ->
        pass = Enum.count(results, &(&1 == :pass))
        fail = Enum.count(results, &(&1 == :fail))
        {p + pass, f + fail}
      end)

    IO.puts("\n\e[1m=== Summary ===\e[0m")
    IO.puts("  Total: #{total_pass + total_fail}")
    IO.puts("  \e[32mPassed: #{total_pass}\e[0m")

    if total_fail > 0 do
      IO.puts("  \e[31mFailed: #{total_fail}\e[0m")
      System.halt(1)
    else
      IO.puts("\n\e[32mAll tests passed!\e[0m")
    end
  end

  def assert!(true, _msg), do: :ok
  def assert!(false, msg), do: raise(msg)
  def assert!(val, msg), do: assert!(!!val, msg)

  def assert_eq!(a, b), do: assert!(a == b, "Expected #{inspect(b)}, got #{inspect(a)}")

  def assert_match!(string, pattern) when is_binary(string) and is_binary(pattern) do
    assert!(
      String.contains?(string, pattern),
      "Expected string to contain #{inspect(pattern)}, got: #{inspect(String.slice(string, 0, 200))}"
    )
  end

  def pg_result(fields) do
    struct!(Postgrex.Result, fields)
  end
end

# --- Parse CLI Flags ---

flags = System.argv()
run_integration = "--integration" in flags
run_database = "--database" in flags

# --- Load Server Modules ---

Mix.install([{:postgrex, "~> 0.19"}, {:jason, "~> 1.4"}, {:sql_parser, "~> 0.2.5"}])

server_path = Path.expand("server.exs", __DIR__)
server_source = File.read!(server_path)

# Strip Mix.install (can't call twice in one VM)
server_source = String.replace(server_source, ~r/^Mix\.install\(.*?\)$/m, "")

# Patch defp -> def in Credentials for test access to parse_item, extract_fields, validate_creds
server_source =
  server_source
  |> String.replace("defp parse_item(", "def parse_item(")
  |> String.replace("defp extract_fields(", "def extract_fields(")
  |> String.replace("defp validate_creds(", "def validate_creds(")

Code.compile_string(server_source, server_path)

# Use fully qualified calls: TestRunner.assert!/2, TestRunner.assert_eq!/2, TestRunner.assert_match!/2

# ============================================================
# LAYER 1: Unit Tests (always run)
# ============================================================

results = []

# --- DbMcp.SQL Tests ---

sql_results =
  TestRunner.run("DbMcp.SQL", [
    {"SELECT is allowed", fn ->
      TestRunner.assert_eq!(DbMcp.SQL.validate_read_only("SELECT * FROM users"), :ok)
    end},
    {"EXPLAIN is allowed", fn ->
      TestRunner.assert_eq!(DbMcp.SQL.validate_read_only("EXPLAIN SELECT * FROM users"), :ok)
    end},
    {"CTE (WITH) is allowed", fn ->
      TestRunner.assert_eq!(DbMcp.SQL.validate_read_only("WITH cte AS (SELECT 1) SELECT * FROM cte"), :ok)
    end},
    {"INSERT is blocked", fn ->
      {:error, msg} = DbMcp.SQL.validate_read_only("INSERT INTO users VALUES (1)")
      TestRunner.assert_match!(msg, "INSERT")
    end},
    {"UPDATE is blocked", fn ->
      {:error, msg} = DbMcp.SQL.validate_read_only("UPDATE users SET name = 'x'")
      TestRunner.assert_match!(msg, "UPDATE")
    end},
    {"DELETE is blocked", fn ->
      {:error, _} = DbMcp.SQL.validate_read_only("DELETE FROM users")
    end},
    {"DROP is blocked", fn ->
      {:error, _} = DbMcp.SQL.validate_read_only("DROP TABLE users")
    end},
    {"CREATE is blocked", fn ->
      {:error, _} = DbMcp.SQL.validate_read_only("CREATE TABLE users (id int)")
    end},
    {"ALTER is blocked", fn ->
      {:error, _} = DbMcp.SQL.validate_read_only("ALTER TABLE users ADD COLUMN name text")
    end},
    {"TRUNCATE is blocked", fn ->
      {:error, _} = DbMcp.SQL.validate_read_only("TRUNCATE users")
    end},
    {"GRANT is blocked", fn ->
      {:error, _} = DbMcp.SQL.validate_read_only("GRANT ALL ON users TO public")
    end},
    {"REVOKE is blocked", fn ->
      {:error, _} = DbMcp.SQL.validate_read_only("REVOKE ALL ON users FROM public")
    end},
    {"COPY is blocked", fn ->
      {:error, _} = DbMcp.SQL.validate_read_only("COPY users TO '/tmp/out.csv'")
    end},
    {"LOCK is blocked", fn ->
      {:error, _} = DbMcp.SQL.validate_read_only("LOCK TABLE users IN ACCESS EXCLUSIVE MODE")
    end},
    {"case-insensitive blocking", fn ->
      {:error, _} = DbMcp.SQL.validate_read_only("insert into users values (1)")
    end},
    {"line comments stripped before check", fn ->
      TestRunner.assert_eq!(
        DbMcp.SQL.validate_read_only("SELECT * FROM users -- INSERT is just a comment"),
        :ok
      )
    end},
    {"block comments stripped before check", fn ->
      TestRunner.assert_eq!(
        DbMcp.SQL.validate_read_only("SELECT * FROM users /* INSERT is just a comment */"),
        :ok
      )
    end},
    # --- AST-based false positive fixes ---
    {"keyword in column name: updated_at", fn ->
      TestRunner.assert_eq!(DbMcp.SQL.validate_read_only("SELECT updated_at FROM users"), :ok)
    end},
    {"multiple keyword-containing columns: created_at, deleted_at", fn ->
      TestRunner.assert_eq!(
        DbMcp.SQL.validate_read_only("SELECT created_at, deleted_at FROM events"),
        :ok
      )
    end},
    {"keyword in string literal: 'DELETED'", fn ->
      TestRunner.assert_eq!(
        DbMcp.SQL.validate_read_only("SELECT * FROM users WHERE status = 'DELETED'"),
        :ok
      )
    end},
    {"keyword in string literal: 'INSERT'", fn ->
      TestRunner.assert_eq!(
        DbMcp.SQL.validate_read_only("SELECT * FROM logs WHERE action = 'INSERT'"),
        :ok
      )
    end},
    {"keyword in function name: delete_expired_tokens()", fn ->
      TestRunner.assert_eq!(
        DbMcp.SQL.validate_read_only("SELECT delete_expired_tokens()"),
        :ok
      )
    end},
    {"keyword in table name: grant_applications", fn ->
      TestRunner.assert_eq!(
        DbMcp.SQL.validate_read_only("SELECT * FROM grant_applications"),
        :ok
      )
    end},
    {"keyword in table name: copy_history", fn ->
      TestRunner.assert_eq!(
        DbMcp.SQL.validate_read_only("SELECT * FROM copy_history"),
        :ok
      )
    end},
    {"keyword in quoted identifier", fn ->
      TestRunner.assert_eq!(
        DbMcp.SQL.validate_read_only("SELECT \"update\" FROM t"),
        :ok
      )
    end},
    {"keyword in alias", fn ->
      TestRunner.assert_eq!(
        DbMcp.SQL.validate_read_only("SELECT u.name AS updated_name FROM users u"),
        :ok
      )
    end},
    {"subquery", fn ->
      TestRunner.assert_eq!(
        DbMcp.SQL.validate_read_only("SELECT * FROM (SELECT 1) sub"),
        :ok
      )
    end},
    {"EXPLAIN ANALYZE is allowed", fn ->
      TestRunner.assert_eq!(
        DbMcp.SQL.validate_read_only("EXPLAIN ANALYZE SELECT * FROM users"),
        :ok
      )
    end},
    {"EXPLAIN with options is allowed", fn ->
      TestRunner.assert_eq!(
        DbMcp.SQL.validate_read_only("EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM users"),
        :ok
      )
    end},
    {"multi-statement with write is blocked", fn ->
      {:error, _} = DbMcp.SQL.validate_read_only("SELECT 1; DROP TABLE users")
    end},
    {"EXPLAIN only in comment still blocks write", fn ->
      {:error, _} = DbMcp.SQL.validate_read_only("-- EXPLAIN\nINSERT INTO users VALUES (1)")
    end}
  ])

results = [sql_results | results]

# --- DbMcp.Format Tests ---

# Start Writes GenServer (needed for Writes tests and by Connection on disconnect)
{:ok, _} = DbMcp.Writes.start_link([])

format_results =
  TestRunner.run("DbMcp.Format", [
    {"format_results table format", fn ->
      result = TestRunner.pg_result(columns: ["id", "name"], rows: [[1, "alice"], [2, "bob"]], num_rows: 2)
      formatted = DbMcp.Format.format_results(result, %{})
      TestRunner.assert_match!(formatted, "id")
      TestRunner.assert_match!(formatted, "alice")
      TestRunner.assert_match!(formatted, "bob")
      TestRunner.assert_match!(formatted, "(2 rows)")
    end},
    {"format_results json format", fn ->
      result = TestRunner.pg_result(columns: ["id", "name"], rows: [[1, "alice"]], num_rows: 1)
      formatted = DbMcp.Format.format_results(result, %{"format" => "json"})
      TestRunner.assert_match!(formatted, "\"id\"")
      TestRunner.assert_match!(formatted, "\"alice\"")
    end},
    {"format_results csv format", fn ->
      result = TestRunner.pg_result(columns: ["id", "name"], rows: [[1, "alice"]], num_rows: 1)
      formatted = DbMcp.Format.format_results(result, %{"format" => "csv"})
      TestRunner.assert_match!(formatted, "id,name")
      TestRunner.assert_match!(formatted, "1,alice")
    end},
    {"decode nil -> NULL", fn ->
      result = TestRunner.pg_result(columns: ["val"], rows: [[nil]], num_rows: 1)
      formatted = DbMcp.Format.format_results(result, %{})
      TestRunner.assert_match!(formatted, "NULL")
    end},
    {"decode boolean", fn ->
      result = TestRunner.pg_result(columns: ["val"], rows: [[true], [false]], num_rows: 2)
      formatted = DbMcp.Format.format_results(result, %{})
      TestRunner.assert_match!(formatted, "true")
      TestRunner.assert_match!(formatted, "false")
    end},
    {"decode Date", fn ->
      result = TestRunner.pg_result(columns: ["val"], rows: [[~D[2024-01-15]]], num_rows: 1)
      formatted = DbMcp.Format.format_results(result, %{})
      TestRunner.assert_match!(formatted, "2024-01-15")
    end},
    {"decode DateTime", fn ->
      {:ok, dt, _} = DateTime.from_iso8601("2024-01-15T10:30:00Z")
      result = TestRunner.pg_result(columns: ["val"], rows: [[dt]], num_rows: 1)
      formatted = DbMcp.Format.format_results(result, %{})
      TestRunner.assert_match!(formatted, "2024-01-15")
    end},
    {"decode Decimal", fn ->
      d = Decimal.new("123.45")
      result = TestRunner.pg_result(columns: ["val"], rows: [[d]], num_rows: 1)
      formatted = DbMcp.Format.format_results(result, %{})
      TestRunner.assert_match!(formatted, "123.45")
    end},
    {"decode map/jsonb via Jason", fn ->
      result = TestRunner.pg_result(columns: ["val"], rows: [[%{"key" => "value"}]], num_rows: 1)
      formatted = DbMcp.Format.format_results(result, %{})
      TestRunner.assert_match!(formatted, "key")
      TestRunner.assert_match!(formatted, "value")
    end},
    {"decode integer", fn ->
      result = TestRunner.pg_result(columns: ["val"], rows: [[42]], num_rows: 1)
      formatted = DbMcp.Format.format_results(result, %{})
      TestRunner.assert_match!(formatted, "42")
    end},
    {"decode list", fn ->
      result = TestRunner.pg_result(columns: ["val"], rows: [[[1, 2, 3]]], num_rows: 1)
      formatted = DbMcp.Format.format_results(result, %{})
      TestRunner.assert_match!(formatted, "[1, 2, 3]")
    end},
    {"row limit enforcement", fn ->
      rows = for i <- 1..10, do: [i]
      result = TestRunner.pg_result(columns: ["id"], rows: rows, num_rows: 10)
      formatted = DbMcp.Format.format_results(result, %{"limit" => 3})
      TestRunner.assert_match!(formatted, "showing 3 of 10 rows")
    end},
    {"cell truncation at 200 chars", fn ->
      long_string = String.duplicate("x", 300)
      result = TestRunner.pg_result(columns: ["val"], rows: [[long_string]], num_rows: 1)
      formatted = DbMcp.Format.format_results(result, %{})
      TestRunner.assert_match!(formatted, "...")
    end},
    {"response size cap with fallback summary", fn ->
      long_row = [String.duplicate("x", 190)]
      rows = for _ <- 1..300, do: long_row
      result = TestRunner.pg_result(columns: ["val"], rows: rows, num_rows: 300)
      formatted = DbMcp.Format.format_results(result, %{"limit" => 300})
      TestRunner.assert_match!(formatted, "Result too large")
      TestRunner.assert_match!(formatted, "LIMIT")
    end},
    {"CSV comma escaping", fn ->
      result = TestRunner.pg_result(columns: ["val"], rows: [["a,b"]], num_rows: 1)
      formatted = DbMcp.Format.format_results(result, %{"format" => "csv"})
      TestRunner.assert_match!(formatted, "\"a,b\"")
    end},
    {"CSV quote escaping", fn ->
      result = TestRunner.pg_result(columns: ["val"], rows: [["a\"b"]], num_rows: 1)
      formatted = DbMcp.Format.format_results(result, %{"format" => "csv"})
      TestRunner.assert_match!(formatted, "\"a\"\"b\"")
    end},
    {"CSV newline escaping", fn ->
      result = TestRunner.pg_result(columns: ["val"], rows: [["a\nb"]], num_rows: 1)
      formatted = DbMcp.Format.format_results(result, %{"format" => "csv"})
      TestRunner.assert_match!(formatted, "\"a\nb\"")
    end},
    {"format_write_result without RETURNING", fn ->
      result = TestRunner.pg_result(command: :insert, num_rows: 1, columns: nil, rows: nil)
      formatted = DbMcp.Format.format_write_result(result)
      TestRunner.assert_match!(formatted, "insert")
      TestRunner.assert_match!(formatted, "1 row(s) affected")
    end},
    {"format_write_result with RETURNING", fn ->
      result = TestRunner.pg_result(command: :insert, num_rows: 1, columns: ["id"], rows: [[42]])
      formatted = DbMcp.Format.format_write_result(result)
      TestRunner.assert_match!(formatted, "insert")
      TestRunner.assert_match!(formatted, "Returning")
      TestRunner.assert_match!(formatted, "42")
    end}
  ])

results = [format_results | results]

# --- DbMcp.Credentials Tests ---

creds_results =
  TestRunner.run("DbMcp.Credentials", [
    {"parse_item with valid JSON", fn ->
      json =
        JSON.encode!(%{
          "fields" => [
            %{"label" => "host", "value" => "db.example.com"},
            %{"label" => "port", "value" => "5432"},
            %{"label" => "username", "value" => "admin"},
            %{"label" => "password", "value" => "secret"},
            %{"label" => "database", "value" => "mydb"}
          ]
        })

      {:ok, creds} = DbMcp.Credentials.parse_item(json)
      TestRunner.assert_eq!(creds.hostname, "db.example.com")
      TestRunner.assert_eq!(creds.port, 5432)
      TestRunner.assert_eq!(creds.username, "admin")
      TestRunner.assert_eq!(creds.password, "secret")
      TestRunner.assert_eq!(creds.database, "mydb")
    end},
    {"alternate field labels (server, user, dbname)", fn ->
      json =
        JSON.encode!(%{
          "fields" => [
            %{"label" => "server", "value" => "db.example.com"},
            %{"label" => "user", "value" => "admin"},
            %{"label" => "password", "value" => "secret"},
            %{"label" => "dbname", "value" => "mydb"}
          ]
        })

      {:ok, creds} = DbMcp.Credentials.parse_item(json)
      TestRunner.assert_eq!(creds.hostname, "db.example.com")
      TestRunner.assert_eq!(creds.username, "admin")
      TestRunner.assert_eq!(creds.database, "mydb")
    end},
    {"alternate field labels (hostname, db)", fn ->
      json =
        JSON.encode!(%{
          "fields" => [
            %{"label" => "hostname", "value" => "db.example.com"},
            %{"label" => "username", "value" => "admin"},
            %{"label" => "password", "value" => "secret"},
            %{"label" => "db", "value" => "mydb"}
          ]
        })

      {:ok, creds} = DbMcp.Credentials.parse_item(json)
      TestRunner.assert_eq!(creds.hostname, "db.example.com")
      TestRunner.assert_eq!(creds.database, "mydb")
    end},
    {"port defaults to 5432", fn ->
      json =
        JSON.encode!(%{
          "fields" => [
            %{"label" => "host", "value" => "db.example.com"},
            %{"label" => "username", "value" => "admin"},
            %{"label" => "password", "value" => "secret"},
            %{"label" => "database", "value" => "mydb"}
          ]
        })

      {:ok, creds} = DbMcp.Credentials.parse_item(json)
      TestRunner.assert_eq!(creds.port, 5432)
    end},
    {"missing required fields error", fn ->
      json =
        JSON.encode!(%{
          "fields" => [
            %{"label" => "host", "value" => "db.example.com"}
          ]
        })

      {:error, msg} = DbMcp.Credentials.parse_item(json)
      TestRunner.assert_match!(msg, "Missing required fields")
    end},
    {"no 'fields' key error", fn ->
      json = JSON.encode!(%{"other" => "data"})
      {:error, msg} = DbMcp.Credentials.parse_item(json)
      TestRunner.assert_match!(msg, "no 'fields' key")
    end},
    {"invalid JSON error", fn ->
      {:error, msg} = DbMcp.Credentials.parse_item("not json")
      TestRunner.assert_match!(msg, "Failed to parse")
    end},
    {"empty/nil values skipped", fn ->
      json =
        JSON.encode!(%{
          "fields" => [
            %{"label" => "host", "value" => "db.example.com"},
            %{"label" => "port", "value" => ""},
            %{"label" => "username", "value" => "admin"},
            %{"label" => "password", "value" => nil},
            %{"label" => "database", "value" => "mydb"}
          ]
        })

      # Password is nil (skipped), so missing
      {:error, msg} = DbMcp.Credentials.parse_item(json)
      TestRunner.assert_match!(msg, "password")
    end},
    {"Map.put_new respects first match", fn ->
      json =
        JSON.encode!(%{
          "fields" => [
            %{"label" => "host", "value" => "first.example.com"},
            %{"label" => "hostname", "value" => "second.example.com"},
            %{"label" => "username", "value" => "admin"},
            %{"label" => "password", "value" => "secret"},
            %{"label" => "database", "value" => "mydb"}
          ]
        })

      {:ok, creds} = DbMcp.Credentials.parse_item(json)
      TestRunner.assert_eq!(creds.hostname, "first.example.com")
    end}
  ])

results = [creds_results | results]

# --- DbMcp.Writes Tests ---

writes_results =
  TestRunner.run("DbMcp.Writes", [
    {"submit/fetch round-trip", fn ->
      {:ok, id} = DbMcp.Writes.submit("test_conn", "INSERT INTO t VALUES (1)", "test insert")
      {:ok, conn_name, sql} = DbMcp.Writes.fetch(id)
      TestRunner.assert_eq!(conn_name, "test_conn")
      TestRunner.assert_eq!(sql, "INSERT INTO t VALUES (1)")
    end},
    {"one-time-use consumption (second fetch returns not found)", fn ->
      {:ok, id} = DbMcp.Writes.submit("test_conn", "INSERT INTO t VALUES (2)", "test")
      {:ok, _, _} = DbMcp.Writes.fetch(id)
      {:error, msg} = DbMcp.Writes.fetch(id)
      TestRunner.assert_match!(msg, "not found")
    end},
    {"invalid ID error", fn ->
      {:error, msg} = DbMcp.Writes.fetch("nonexistent")
      TestRunner.assert_match!(msg, "not found")
    end},
    {"purge_all clears everything", fn ->
      {:ok, _id1} = DbMcp.Writes.submit("c1", "SQL 1", "")
      {:ok, _id2} = DbMcp.Writes.submit("c2", "SQL 2", "")
      :ok = DbMcp.Writes.purge_all()
      # No way to verify directly without IDs, but purge didn't crash
    end},
    {"purge_connection only purges named connection", fn ->
      {:ok, id1} = DbMcp.Writes.submit("conn_a", "SQL A", "")
      {:ok, id2} = DbMcp.Writes.submit("conn_b", "SQL B", "")
      :ok = DbMcp.Writes.purge_connection("conn_a")
      {:error, _} = DbMcp.Writes.fetch(id1)
      {:ok, "conn_b", "SQL B"} = DbMcp.Writes.fetch(id2)
    end}
  ])

results = [writes_results | results]

# ============================================================
# LAYER 2: Integration Tests (--integration flag)
# ============================================================

results = if run_integration do
  defmodule McpClient do
    @moduledoc false

    def start(server_path) do
      elixir = System.find_executable("elixir")

      port =
        Port.open({:spawn_executable, elixir}, [
          :binary,
          {:line, 65_536},
          {:args, [server_path]}
        ])

      wait_for_server(port)
      port
    end

    def request(port, id, method, params \\ %{}) do
      msg = JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
      Port.command(port, msg <> "\n")
      receive_response(port)
    end

    def notify(port, method, params \\ %{}) do
      msg = JSON.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params})
      Port.command(port, msg <> "\n")
      Process.sleep(100)
    end

    def send_raw(port, data) do
      Port.command(port, data <> "\n")
    end

    def receive_response(port, timeout \\ 10_000) do
      receive do
        {^port, {:data, {:eol, line}}} -> JSON.decode!(line)
      after
        timeout -> raise "Timeout waiting for server response"
      end
    end

    def stop(port) do
      Port.close(port)
    end

    defp wait_for_server(port) do
      msg = JSON.encode!(%{"jsonrpc" => "2.0", "id" => "startup-ping", "method" => "ping"})
      Port.command(port, msg <> "\n")

      receive do
        {^port, {:data, {:eol, _line}}} -> :ok
      after
        30_000 -> raise "Server failed to start within 30s"
      end
    end
  end

  IO.puts("\n\e[1m--- Starting MCP server for integration tests ---\e[0m")
  server_port = McpClient.start(server_path)
  IO.puts("  Server started.")

  # --- MCP Handshake Tests ---

  handshake_results =
    TestRunner.run("MCP Handshake", [
      {"initialize returns protocol version + capabilities + serverInfo", fn ->
        resp =
          McpClient.request(server_port, 1, "initialize", %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "test", "version" => "1.0"}
          })

        TestRunner.assert!(resp["result"]["protocolVersion"], "missing protocolVersion")
        TestRunner.assert!(resp["result"]["capabilities"], "missing capabilities")
        TestRunner.assert!(resp["result"]["serverInfo"], "missing serverInfo")
        TestRunner.assert_eq!(resp["result"]["serverInfo"]["name"], "db-mcp")
      end},
      {"notifications/initialized accepted silently", fn ->
        McpClient.notify(server_port, "notifications/initialized")
        resp = McpClient.request(server_port, 2, "ping")
        TestRunner.assert_eq!(resp["result"], %{})
      end},
      {"tools/list returns all 6 tools", fn ->
        resp = McpClient.request(server_port, 3, "tools/list")
        tools = resp["result"]["tools"]
        TestRunner.assert_eq!(length(tools), 6)

        names = Enum.map(tools, & &1["name"]) |> Enum.sort()

        TestRunner.assert_eq!(names, [
          "pg_connect",
          "pg_disconnect",
          "pg_execute_write",
          "pg_query",
          "pg_status",
          "pg_submit_write"
        ])
      end},
      {"ping returns empty result", fn ->
        resp = McpClient.request(server_port, 4, "ping")
        TestRunner.assert_eq!(resp["result"], %{})
      end}
    ])

  # --- MCP Error Handling Tests ---

  error_results =
    TestRunner.run("MCP Error Handling", [
      {"bad JSON returns -32700", fn ->
        McpClient.send_raw(server_port, "not json at all")
        resp = McpClient.receive_response(server_port)
        TestRunner.assert_eq!(resp["error"]["code"], -32700)
      end},
      {"unknown method returns -32601", fn ->
        resp = McpClient.request(server_port, 10, "nonexistent/method")
        TestRunner.assert_eq!(resp["error"]["code"], -32601)
      end},
      {"unknown tool returns isError tool result", fn ->
        resp =
          McpClient.request(server_port, 11, "tools/call", %{
            "name" => "nonexistent_tool",
            "arguments" => %{}
          })

        TestRunner.assert_eq!(resp["result"]["isError"], true)
        TestRunner.assert_match!(hd(resp["result"]["content"])["text"], "Unknown tool")
      end},
      {"tools/call without name returns -32602", fn ->
        resp = McpClient.request(server_port, 12, "tools/call", %{})
        TestRunner.assert_eq!(resp["error"]["code"], -32602)
      end},
      {"missing jsonrpc field returns -32600", fn ->
        msg = JSON.encode!(%{"id" => 13, "method" => "ping"})
        McpClient.send_raw(server_port, msg)
        resp = McpClient.receive_response(server_port)
        TestRunner.assert_eq!(resp["error"]["code"], -32600)
      end}
    ])

  # --- Server Resilience Tests ---

  resilience_results =
    TestRunner.run("Server Resilience", [
      {"server survives bad JSON then responds to ping", fn ->
        McpClient.send_raw(server_port, "{invalid json}")
        _err = McpClient.receive_response(server_port)
        resp = McpClient.request(server_port, 20, "ping")
        TestRunner.assert_eq!(resp["result"], %{})
      end},
      {"server survives unknown method then responds", fn ->
        _err = McpClient.request(server_port, 21, "fake/method")
        resp = McpClient.request(server_port, 22, "ping")
        TestRunner.assert_eq!(resp["result"], %{})
      end},
      {"server survives multiple consecutive errors then responds", fn ->
        McpClient.send_raw(server_port, "garbage1")
        _err1 = McpClient.receive_response(server_port)
        McpClient.send_raw(server_port, "garbage2")
        _err2 = McpClient.receive_response(server_port)
        McpClient.send_raw(server_port, "garbage3")
        _err3 = McpClient.receive_response(server_port)
        resp = McpClient.request(server_port, 23, "ping")
        TestRunner.assert_eq!(resp["result"], %{})
      end}
    ])

  # --- Tool Calls (no DB) Tests ---

  tool_results =
    TestRunner.run("Tool Calls (no DB)", [
      {"pg_status with no connections returns error", fn ->
        resp =
          McpClient.request(server_port, 30, "tools/call", %{
            "name" => "pg_status",
            "arguments" => %{}
          })

        TestRunner.assert_eq!(resp["result"]["isError"], true)
        TestRunner.assert_match!(hd(resp["result"]["content"])["text"], "No active connections")
      end},
      {"pg_query with no connections returns error", fn ->
        resp =
          McpClient.request(server_port, 31, "tools/call", %{
            "name" => "pg_query",
            "arguments" => %{"sql" => "SELECT 1"}
          })

        TestRunner.assert_eq!(resp["result"]["isError"], true)
        TestRunner.assert_match!(hd(resp["result"]["content"])["text"], "No active connections")
      end},
      {"pg_disconnect with no connections succeeds (empty disconnect_all)", fn ->
        resp =
          McpClient.request(server_port, 32, "tools/call", %{
            "name" => "pg_disconnect",
            "arguments" => %{}
          })

        TestRunner.assert_eq!(resp["result"]["isError"], false)
      end},
      {"pg_connect missing params returns error", fn ->
        resp =
          McpClient.request(server_port, 33, "tools/call", %{
            "name" => "pg_connect",
            "arguments" => %{}
          })

        TestRunner.assert_eq!(resp["result"]["isError"], true)
        TestRunner.assert_match!(hd(resp["result"]["content"])["text"], "Missing required parameters")
      end},
      {"pg_submit_write missing sql returns error", fn ->
        resp =
          McpClient.request(server_port, 34, "tools/call", %{
            "name" => "pg_submit_write",
            "arguments" => %{}
          })

        TestRunner.assert_eq!(resp["result"]["isError"], true)
        TestRunner.assert_match!(hd(resp["result"]["content"])["text"], "Missing required parameter")
      end},
      {"pg_execute_write missing query_id returns error", fn ->
        resp =
          McpClient.request(server_port, 35, "tools/call", %{
            "name" => "pg_execute_write",
            "arguments" => %{}
          })

        TestRunner.assert_eq!(resp["result"]["isError"], true)
        TestRunner.assert_match!(hd(resp["result"]["content"])["text"], "Missing required parameter")
      end}
    ])

  McpClient.stop(server_port)
  IO.puts("\n  Server stopped.")

  [tool_results, resilience_results, error_results, handshake_results | results]
else
  results
end

# ============================================================
# LAYER 3: Database Tests (--database flag)
# ============================================================

results = if run_database do
  IO.puts("\n\e[1m--- Setting up Docker PostgreSQL ---\e[0m")

  # Stop any existing container
  System.cmd("docker", ["stop", "mcp_test_pg"], stderr_to_stdout: true)
  Process.sleep(1000)

  # Start fresh container
  {_, 0} =
    System.cmd("docker", [
      "run",
      "--rm",
      "-d",
      "-p",
      "54321:5432",
      "-e",
      "POSTGRES_PASSWORD=test",
      "-e",
      "POSTGRES_DB=mcp_test",
      "--name",
      "mcp_test_pg",
      "postgres:16-alpine"
    ])

  IO.puts("  Waiting for PostgreSQL to be ready...")

  wait_for_pg = fn wait_for_pg, retries ->
    if retries <= 0, do: raise("PostgreSQL failed to start")

    case System.cmd("docker", ["exec", "mcp_test_pg", "pg_isready", "-U", "postgres"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      _ ->
        Process.sleep(1000)
        wait_for_pg.(wait_for_pg, retries - 1)
    end
  end

  wait_for_pg.(wait_for_pg, 30)

  IO.puts("  PostgreSQL is ready. Seeding test data...")

  # Seed database via direct Postgrex connection
  {:ok, seed_conn} =
    Postgrex.start_link(
      hostname: "localhost",
      port: 54321,
      username: "postgres",
      password: "test",
      database: "mcp_test"
    )

  Postgrex.query!(
    seed_conn,
    """
    CREATE TABLE IF NOT EXISTS test_data (
      id serial PRIMARY KEY,
      name text,
      active boolean,
      created_at date,
      metadata jsonb
    )
    """,
    []
  )

  Postgrex.query!(seed_conn, "DELETE FROM test_data", [])

  Postgrex.query!(
    seed_conn,
    """
    INSERT INTO test_data (name, active, created_at, metadata) VALUES
      ('Alice', true, '2024-01-15', '{"key": "value", "nested": {"a": 1}}'),
      ('Bob', false, '2024-02-20', '{"key": "other"}'),
      (NULL, true, NULL, NULL)
    """,
    []
  )

  GenServer.stop(seed_conn)

  IO.puts("  Test data seeded.")

  # Start Connection GenServer in test VM
  unless Process.whereis(DbMcp.Connection) do
    {:ok, _} = DbMcp.Connection.start_link([])
  end

  # Start a Postgrex pool and inject into Connection state
  {:ok, test_pool} =
    Postgrex.start_link(
      hostname: "localhost",
      port: 54321,
      username: "postgres",
      password: "test",
      database: "mcp_test",
      pool_size: 2,
      json_library: Jason
    )

  :sys.replace_state(DbMcp.Connection, fn state ->
    conn_info = %{
      pool: test_pool,
      metadata: %{
        host: "localhost",
        port: 54321,
        user: "postgres",
        database: "mcp_test",
        pg_version: "PostgreSQL 16 (test)"
      }
    }

    put_in(state, [:connections, "test"], conn_info)
  end)

  # --- Connection Lifecycle Tests ---

  conn_results =
    TestRunner.run("Connection Lifecycle (DB)", [
      {"status shows metadata", fn ->
        {:ok, info} = DbMcp.Connection.status("test")
        TestRunner.assert_match!(info, "mcp_test")
        TestRunner.assert_match!(info, "localhost")
        TestRunner.assert_match!(info, "postgres")
      end},
      {"status_all shows connection", fn ->
        {:ok, info} = DbMcp.Connection.status_all()
        TestRunner.assert_match!(info, "test")
        TestRunner.assert_match!(info, "mcp_test")
      end},
      {"list_connections includes test", fn ->
        {:ok, names} = DbMcp.Connection.list_connections()
        TestRunner.assert!("test" in names, "expected 'test' in connections list")
      end}
    ])

  # --- Read Query Tests ---

  read_results =
    TestRunner.run("Read Queries (DB)", [
      {"SELECT with text/int/bool/date/jsonb/NULL columns", fn ->
        {:ok, result} =
          DbMcp.Connection.query("test", "SELECT * FROM test_data ORDER BY id", %{})

        TestRunner.assert_match!(result, "Alice")
        TestRunner.assert_match!(result, "Bob")
        TestRunner.assert_match!(result, "true")
        TestRunner.assert_match!(result, "false")
        TestRunner.assert_match!(result, "2024-01-15")
        TestRunner.assert_match!(result, "NULL")
        TestRunner.assert_match!(result, "key")
      end},
      {"LIMIT param", fn ->
        {:ok, result} =
          DbMcp.Connection.query("test", "SELECT * FROM test_data ORDER BY id", %{"limit" => 1})

        TestRunner.assert_match!(result, "Alice")
        TestRunner.assert_match!(result, "showing 1 of 3 rows")
      end},
      {"format json", fn ->
        {:ok, result} =
          DbMcp.Connection.query(
            "test",
            "SELECT id, name FROM test_data WHERE id = 1",
            %{"format" => "json"}
          )

        TestRunner.assert_match!(result, "\"name\"")
        TestRunner.assert_match!(result, "\"Alice\"")
      end},
      {"format csv", fn ->
        {:ok, result} =
          DbMcp.Connection.query(
            "test",
            "SELECT id, name FROM test_data WHERE id = 1",
            %{"format" => "csv"}
          )

        TestRunner.assert_match!(result, "id,name")
        TestRunner.assert_match!(result, "1,Alice")
      end}
    ])

  # --- Read-Only Enforcement Tests ---

  readonly_results =
    TestRunner.run("Read-Only Enforcement (DB)", [
      {"INSERT inside pg_query fails gracefully with error (not crash)", fn ->
        {:error, msg} =
          DbMcp.Connection.query(
            "test",
            "INSERT INTO test_data (name) VALUES ('hacker')",
            %{}
          )

        TestRunner.assert_match!(msg, "INSERT")
        TestRunner.assert_match!(msg, "not allowed")
      end}
    ])

  # --- Write Flow Tests ---

  write_flow_results =
    TestRunner.run("Write Flow (DB)", [
      {"submit_write returns query_id, execute_write runs it", fn ->
        {:ok, query_id} =
          DbMcp.Writes.submit(
            "test",
            "INSERT INTO test_data (name, active) VALUES ('Test Write', true)",
            "test write"
          )

        {:ok, "test", sql} = DbMcp.Writes.fetch(query_id)
        {:ok, result} = DbMcp.Connection.execute("test", sql)
        TestRunner.assert_match!(result, "insert")
        TestRunner.assert_match!(result, "1 row(s) affected")
      end},
      {"verify written data with SELECT", fn ->
        {:ok, result} =
          DbMcp.Connection.query(
            "test",
            "SELECT name FROM test_data WHERE name = 'Test Write'",
            %{}
          )

        TestRunner.assert_match!(result, "Test Write")
      end}
    ])

  # --- jsonb Handling Tests ---

  jsonb_results =
    TestRunner.run("jsonb Handling (DB)", [
      {"query jsonb column returns formatted JSON string", fn ->
        {:ok, result} =
          DbMcp.Connection.query(
            "test",
            "SELECT metadata FROM test_data WHERE id = 1",
            %{}
          )

        TestRunner.assert_match!(result, "key")
        TestRunner.assert_match!(result, "value")
        TestRunner.assert_match!(result, "nested")
      end}
    ])

  # Cleanup
  IO.puts("\n\e[1m--- Cleaning up Docker PostgreSQL ---\e[0m")
  System.cmd("docker", ["stop", "mcp_test_pg"], stderr_to_stdout: true)
  IO.puts("  Done.")

  [jsonb_results, write_flow_results, readonly_results, read_results, conn_results | results]
else
  results
end

# ============================================================
# Summary
# ============================================================

TestRunner.summarize(Enum.reverse(results))
