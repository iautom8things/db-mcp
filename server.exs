#!/usr/bin/env elixir

# DB MCP Server - PostgreSQL database access via MCP over stdio
#
# Provides persistent database connections through 1Password credential lookup.
# Supports multiple simultaneous named connections.
#
# Read queries (pg_query) execute instantly via Postgrex — no approval needed.
# Write queries (pg_submit_write) block until the user approves them in the
# web UI, then execute immediately on approval.
#
# A psql PTY session is started for each connection and exposed via xterm.js
# in the browser, so the user can also interact with the database directly.
#
# Usage:
#   elixir server.exs

Mix.install([
  {:postgrex, "~> 0.19"},
  {:jason, "~> 1.4"},
  {:sql_parser, "~> 0.2.5"},
  {:bandit, "~> 1.0"},
  {:websock_adapter, "~> 0.5"}
])

Logger.configure(level: :warning)

defmodule DbMcp.Log do
  @moduledoc false

  # Writing to :stderr can raise ArgumentError ("the device does not exist")
  # if the launcher closed standard_error on the child process. Logging is a
  # side effect — never let it crash the BEAM.
  def info(msg), do: write("[INFO] #{msg}")
  def error(msg), do: write("[ERROR] #{msg}")
  def debug(msg), do: write("[DEBUG] #{msg}")

  defp write(line) do
    try do
      IO.puts(:stderr, line)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end
end

defmodule DbMcp.Credentials do
  @moduledoc false

  @default_op_account "team-chapterspot"

  @field_mappings %{
    "host" => :hostname,
    "hostname" => :hostname,
    "server" => :hostname,
    "port" => :port,
    "username" => :username,
    "user" => :username,
    "password" => :password,
    "database" => :database,
    "dbname" => :database,
    "db" => :database
  }

  def fetch(vault_id, item_name) do
    DbMcp.Log.info("Fetching credentials from 1Password: vault=#{vault_id}, item=#{item_name}")

    op_bin = System.get_env("DB_MCP_OP_BIN") || "op"
    op_account = op_account()

    args = [
      "item",
      "get",
      item_name,
      "--account",
      op_account,
      "--vault",
      vault_id,
      "--format",
      "json"
    ]

    case System.cmd(op_bin, args, stderr_to_stdout: true) do
      {output, 0} ->
        parse_item(output)

      {error_output, code} ->
        {:error, "1Password lookup failed: #{op_error(error_output, code)}"}
    end
  end

  defp op_account do
    case System.get_env("DB_MCP_OP_ACCOUNT") do
      nil -> @default_op_account
      "" -> @default_op_account
      account -> account
    end
  end

  defp op_error(output, code) do
    case String.trim(output) do
      "" -> "op exited with status #{code}"
      message -> message
    end
  end

  defp parse_item(json) do
    case JSON.decode(json) do
      {:ok, %{"fields" => fields}} ->
        creds = extract_fields(fields)
        validate_creds(creds)

      {:ok, _} ->
        {:error, "Unexpected 1Password item format: no 'fields' key"}

      {:error, _} ->
        {:error, "Failed to parse 1Password JSON response"}
    end
  end

  defp extract_fields(fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      label = field["label"] || ""
      value = field["value"]
      normalized = String.downcase(label)

      case Map.get(@field_mappings, normalized) do
        nil -> acc
        _key when is_nil(value) or value == "" -> acc
        key -> Map.put_new(acc, key, value)
      end
    end)
  end

  defp validate_creds(creds) do
    required = [:hostname, :username, :password, :database]
    missing = Enum.filter(required, &(not Map.has_key?(creds, &1)))

    case missing do
      [] ->
        port = Map.get(creds, :port, "5432")

        {:ok,
         %{
           hostname: creds.hostname,
           port: String.to_integer(port),
           username: creds.username,
           password: creds.password,
           database: creds.database
         }}

      fields ->
        {:error, "Missing required fields: #{Enum.join(fields, ", ")}"}
    end
  end
end

defmodule DbMcp.SQL do
  @moduledoc false

  @explain_pattern ~r/\A\s*EXPLAIN\b/i
  @write_keywords ~w(INSERT UPDATE DELETE DROP CREATE ALTER TRUNCATE GRANT REVOKE COPY LOCK)

  def validate_read_only(sql) do
    case SqlParser.parse(sql, dialect: :postgres) do
      {:ok, statements} ->
        validate_statements(statements, sql)

      {:error, _reason} ->
        check_first_keyword(sql)
    end
  end

  defp validate_statements([], _sql), do: :ok

  defp validate_statements(statements, sql) do
    if Enum.all?(statements, &read_only_statement?/1) do
      :ok
    else
      if Regex.match?(@explain_pattern, strip_comments(sql)) do
        :ok
      else
        keyword = extract_first_keyword(sql)

        {:error,
         "Query contains '#{keyword}' which is not allowed in read-only mode. " <>
           "Use the 'pg_submit_write' tool for write operations."}
      end
    end
  end

  defp read_only_statement?(%SqlParser.Query{}), do: true
  defp read_only_statement?(_), do: false

  defp check_first_keyword(sql) do
    keyword = extract_first_keyword(sql)

    if keyword in @write_keywords do
      {:error,
       "Query contains '#{keyword}' which is not allowed in read-only mode. " <>
         "Use the 'pg_submit_write' tool for write operations."}
    else
      :ok
    end
  end

  defp extract_first_keyword(sql) do
    sql
    |> strip_comments()
    |> String.split(~r/\s+/, parts: 2)
    |> hd()
    |> String.upcase()
  end

  defp strip_comments(sql) do
    sql
    |> String.replace(~r/--.*$/m, "")
    |> String.replace(~r/\/\*.*?\*\//s, "")
    |> String.trim()
  end
end

defmodule DbMcp.Format do
  @moduledoc false

  @max_cell_length 200
  @max_response_bytes 50_000

  def format_results(%Postgrex.Result{columns: columns, rows: rows, num_rows: num_rows}, opts) do
    format = Map.get(opts, "format", "table")
    limit = min(Map.get(opts, "limit", 100), 1000)

    display_rows = Enum.take(rows, limit)
    decoded_rows = Enum.map(display_rows, fn row -> Enum.map(row, &decode_value/1) end)

    formatted =
      case format do
        "json" -> format_json(columns, decoded_rows)
        "csv" -> format_csv(columns, decoded_rows)
        _ -> format_table(columns, decoded_rows)
      end

    footer =
      if num_rows > limit do
        "(showing #{limit} of #{num_rows} rows)"
      else
        "(#{num_rows} rows)"
      end

    result = "#{formatted}\n\n#{footer}"

    if byte_size(result) > @max_response_bytes do
      "Result too large (#{byte_size(result)} bytes). Showing summary instead.\n\n" <>
        "Columns: #{Enum.join(columns, ", ")}\n" <>
        "Total rows: #{num_rows}\n" <>
        "Try adding a LIMIT clause or filtering your query."
    else
      result
    end
  end

  def format_write_result(%Postgrex.Result{
        command: command,
        num_rows: num_rows,
        columns: columns,
        rows: rows
      }) do
    base = "#{command}: #{num_rows} row(s) affected"

    if columns && length(columns) > 0 && rows && length(rows) > 0 do
      decoded_rows = Enum.map(rows, fn row -> Enum.map(row, &decode_value/1) end)
      table = format_table(columns, decoded_rows)
      "#{base}\n\nReturning:\n#{table}"
    else
      base
    end
  end

  defp format_table(columns, rows) do
    all_data = [columns | Enum.map(rows, fn row -> Enum.map(row, &truncate/1) end)]

    widths =
      Enum.map(0..(length(columns) - 1), fn i ->
        all_data
        |> Enum.map(fn row -> row |> Enum.at(i, "") |> String.length() end)
        |> Enum.max()
      end)

    header = format_row(columns, widths)
    separator = Enum.map(widths, fn w -> String.duplicate("-", w) end) |> Enum.join(" | ")
    separator = "| #{separator} |"

    data_rows =
      rows
      |> Enum.map(fn row -> row |> Enum.map(&truncate/1) |> format_row(widths) end)

    [header, separator | data_rows] |> Enum.join("\n")
  end

  defp format_row(cells, widths) do
    padded =
      Enum.zip(cells, widths)
      |> Enum.map(fn {cell, width} -> String.pad_trailing(cell, width) end)

    "| #{Enum.join(padded, " | ")} |"
  end

  defp format_json(columns, rows) do
    objects =
      Enum.map(rows, fn row ->
        Enum.zip(columns, row) |> Map.new()
      end)

    JSON.encode!(objects)
  end

  defp format_csv(columns, rows) do
    header = Enum.join(columns, ",")

    data_rows =
      Enum.map(rows, fn row ->
        Enum.map(row, &csv_escape/1) |> Enum.join(",")
      end)

    [header | data_rows] |> Enum.join("\n")
  end

  defp csv_escape(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"#{String.replace(value, "\"", "\"\"")}\""
    else
      value
    end
  end

  defp decode_value(nil), do: "NULL"
  defp decode_value(%Decimal{} = d), do: Decimal.to_string(d)
  defp decode_value(%Date{} = d), do: Date.to_iso8601(d)
  defp decode_value(%Time{} = t), do: Time.to_iso8601(t)
  defp decode_value(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp decode_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp decode_value(v) when is_binary(v), do: v
  defp decode_value(v) when is_integer(v), do: Integer.to_string(v)
  defp decode_value(v) when is_float(v), do: Float.to_string(v)
  defp decode_value(true), do: "true"
  defp decode_value(false), do: "false"
  defp decode_value(v) when is_list(v), do: inspect(v)
  defp decode_value(v) when is_map(v), do: Jason.encode!(v)
  defp decode_value(v), do: inspect(v)

  defp truncate(value) do
    if String.length(value) > @max_cell_length do
      String.slice(value, 0, @max_cell_length - 3) <> "..."
    else
      value
    end
  end
end

defmodule DbMcp.Pty do
  @moduledoc """
  Manages a psql PTY session for interactive use in the browser.

  The PTY is started when pg_connect is called and provides a full interactive
  psql experience via xterm.js. Claude's reads go through Postgrex directly —
  the PTY is strictly for the user's interactive use and for displaying write
  queries pending approval.
  """

  use GenServer

  @max_scrollback 256_000

  defstruct [
    :port,
    :name,
    :metadata,
    connected: false,
    subscribers: MapSet.new(),
    scrollback: ""
  ]

  def start_link, do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  def get_state, do: GenServer.call(__MODULE__, :get_state)
  def connect(name, creds), do: GenServer.call(__MODULE__, {:connect, name, creds}, 30_000)
  def disconnect(name), do: GenServer.call(__MODULE__, {:disconnect, name}, 15_000)
  def write(data), do: GenServer.cast(__MODULE__, {:write, data})
  def resize(cols, rows), do: GenServer.cast(__MODULE__, {:resize, cols, rows})
  def subscribe(pid), do: GenServer.cast(__MODULE__, {:subscribe, pid})
  def unsubscribe(pid), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})
  def get_scrollback(n \\ 100), do: GenServer.call(__MODULE__, {:get_scrollback, n})
  def search_scrollback(query), do: GenServer.call(__MODULE__, {:search_scrollback, query})

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    info = %{
      connected: state.connected,
      name: state.name,
      metadata: state.metadata
    }

    {:reply, info, state}
  end

  @impl GenServer
  def handle_call({:connect, name, creds}, _from, state) do
    # Gracefully shut down any existing PTY session
    if state.connected and state.port do
      Port.command(state.port, <<0x02>>)
    end

    bridge_path = Path.join(__DIR__, "pty_bridge.py")
    python = System.get_env("DB_MCP_PYTHON_BIN") || System.find_executable("python3") || "python3"

    port =
      Port.open(
        {:spawn_executable, python},
        [:binary, {:packet, 4}, {:args, [bridge_path]}, :exit_status, :hide]
      )

    init_config =
      Jason.encode!(%{
        type: "init",
        command: "psql",
        args: [
          "-h",
          creds.hostname,
          "-p",
          "#{creds.port}",
          "-U",
          creds.username,
          "-d",
          creds.database,
          "--pset=pager=off"
        ],
        cols: 220,
        rows: 50,
        env: %{
          "PGPASSWORD" => creds.password,
          "TERM" => "xterm-256color",
          "PAGER" => "cat"
        }
      })

    Port.command(port, <<0x01, init_config::binary>>)

    new_state = %__MODULE__{
      port: port,
      name: name,
      metadata: %{
        host: creds.hostname,
        port: creds.port,
        database: creds.database,
        user: creds.username
      },
      connected: true,
      subscribers: state.subscribers,
      scrollback: ""
    }

    DbMcp.Log.info("Started psql PTY for '#{name}' (#{creds.database} on #{creds.hostname})")
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:disconnect, name}, _from, state) do
    if state.connected and state.name == name and state.port do
      Port.command(state.port, <<0x02>>)
      DbMcp.Log.info("Stopped psql PTY for '#{name}'")
      {:reply, :ok, %__MODULE__{subscribers: state.subscribers}}
    else
      {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_call({:get_scrollback, last_n_lines}, _from, state) do
    lines =
      state.scrollback
      |> strip_ansi()
      |> String.split(~r/\r?\n/)
      |> Enum.take(-last_n_lines)
      |> Enum.join("\n")

    {:reply, lines, state}
  end

  @impl GenServer
  def handle_call({:search_scrollback, query}, _from, state) do
    clean = strip_ansi(state.scrollback)
    lines = String.split(clean, ~r/\r?\n/)
    query_down = String.downcase(query)

    matches =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _idx} -> String.contains?(String.downcase(line), query_down) end)
      |> Enum.map(fn {line, idx} ->
        start_idx = max(idx - 3, 0)
        end_idx = min(idx + 1, length(lines) - 1)
        context = Enum.slice(lines, start_idx..end_idx) |> Enum.join("\n")
        %{line: idx, match: String.trim(line), context: context}
      end)

    {:reply, matches, state}
  end

  @impl GenServer
  def handle_cast({:write, data}, state) do
    if state.connected and state.port do
      Port.command(state.port, <<0x00, data::binary>>)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:resize, cols, rows}, state) do
    if state.connected and state.port do
      control = Jason.encode!(%{type: "resize", cols: cols, rows: rows})
      Port.command(state.port, <<0x01, control::binary>>)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:subscribe, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl GenServer
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl GenServer
  def handle_info({port, {:data, <<0x00, data::binary>>}}, %{port: port} = state) do
    for pid <- state.subscribers, do: send(pid, {:pty_output, data})

    scrollback = state.scrollback <> data

    scrollback =
      if byte_size(scrollback) > @max_scrollback do
        binary_part(
          scrollback,
          byte_size(scrollback) - div(@max_scrollback, 2),
          div(@max_scrollback, 2)
        )
      else
        scrollback
      end

    {:noreply, %{state | scrollback: scrollback}}
  end

  @impl GenServer
  def handle_info({port, {:data, <<0x01, json::binary>>}}, %{port: port} = state) do
    case Jason.decode(json) do
      {:ok, %{"type" => "started", "pid" => pid}} ->
        DbMcp.Log.info("psql PTY bridge started, child PID: #{pid}")
        {:noreply, state}

      {:ok, %{"type" => "exited", "exit_code" => code}} ->
        DbMcp.Log.info("psql PTY exited with code #{code}")
        for pid <- state.subscribers, do: send(pid, :pty_closed)
        {:noreply, %__MODULE__{subscribers: state.subscribers}}

      {:ok, %{"type" => "error", "message" => msg}} ->
        DbMcp.Log.error("PTY bridge error: #{msg}")
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    DbMcp.Log.info("psql PTY port exited with status #{code}")
    for pid <- state.subscribers, do: send(pid, :pty_closed)
    {:noreply, %__MODULE__{subscribers: state.subscribers}}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  defp strip_ansi(text), do: Regex.replace(~r/\x1b\[[0-9;]*[a-zA-Z]/, text, "")
end

defmodule DbMcp.Activity do
  @moduledoc """
  Tracks MCP tool calls (pg_query, pg_submit_write) and broadcasts them
  to subscribers for display in the web UI activity pane.
  """

  use GenServer

  @max_events 200

  defstruct subscribers: MapSet.new(), events: []

  def start_link, do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  def subscribe(pid), do: GenServer.cast(__MODULE__, {:subscribe, pid})
  def unsubscribe(pid), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})
  def recent(n \\ 50), do: GenServer.call(__MODULE__, {:recent, n})

  def push(tool, sql, result, status) do
    GenServer.cast(__MODULE__, {:push, tool, sql, result, status})
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_cast({:subscribe, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl GenServer
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl GenServer
  def handle_cast({:push, tool, sql, result, status}, state) do
    event = %{
      tool: tool,
      sql: sql,
      result: result,
      status: status,
      at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    json = Jason.encode!(%{type: "activity", event: event})
    for pid <- state.subscribers, do: send(pid, {:activity, json})

    events = [event | state.events] |> Enum.take(@max_events)
    {:noreply, %{state | events: events}}
  end

  @impl GenServer
  def handle_call({:recent, n}, _from, state) do
    {:reply, Enum.take(state.events, n), state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}
end

defmodule DbMcp.Approval do
  @moduledoc """
  Manages a single pending write query awaiting user approval in the web UI.

  pg_submit_write calls submit_and_wait/3, which blocks the caller until the
  user approves or rejects the query in the browser. On approval the caller
  proceeds to execute; on rejection it returns immediately without executing.
  """

  use GenServer

  defstruct pending: nil

  def start_link, do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  def get_pending, do: GenServer.call(__MODULE__, :get_pending)

  def submit_and_wait(sql, description, connection_name) do
    GenServer.call(
      __MODULE__,
      {:submit, sql, description, connection_name},
      to_timeout(minute: 30)
    )
  end

  def respond(id, decision) when decision in [:approve, :reject] do
    GenServer.cast(__MODULE__, {:respond, id, decision})
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call(:get_pending, _from, state), do: {:reply, state.pending, state}

  @impl GenServer
  def handle_call({:submit, sql, description, connection_name}, from, state) do
    if state.pending do
      {:reply, {:error, "Another approval is already pending"}, state}
    else
      id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

      pending = %{
        id: id,
        sql: sql,
        description: description,
        connection_name: connection_name,
        from: from,
        submitted_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      DbMcp.Log.info(
        "Write approval pending: #{id} — review at http://localhost:#{DbMcp.Server.web_port()}"
      )

      {:noreply, %{state | pending: pending}}
    end
  end

  @impl GenServer
  def handle_cast({:respond, id, decision}, state) do
    case state.pending do
      %{id: ^id, from: from} ->
        GenServer.reply(from, decision)
        DbMcp.Log.info("Write approval #{id}: #{decision}")
        {:noreply, %{state | pending: nil}}

      _ ->
        DbMcp.Log.error("No pending approval with id #{id}")
        {:noreply, state}
    end
  end
end

defmodule DbMcp.WsHandler do
  @moduledoc false
  @behaviour WebSock

  @impl WebSock
  def init(_opts) do
    DbMcp.Pty.subscribe(self())
    DbMcp.Activity.subscribe(self())

    # Send recent activity to catch up
    for event <- DbMcp.Activity.recent() |> Enum.reverse() do
      send(self(), {:activity, Jason.encode!(%{type: "activity", event: event})})
    end

    {:ok, %{}}
  end

  @impl WebSock
  def handle_in({data, [opcode: :binary]}, state) do
    DbMcp.Pty.write(data)
    {:ok, state}
  end

  @impl WebSock
  def handle_in({data, [opcode: :text]}, state) do
    case Jason.decode(data) do
      {:ok, %{"type" => "resize", "cols" => cols, "rows" => rows}} ->
        DbMcp.Pty.resize(cols, rows)

      _ ->
        :ok
    end

    {:ok, state}
  end

  @impl WebSock
  def handle_info({:pty_output, data}, state) do
    {:push, {:binary, data}, state}
  end

  @impl WebSock
  def handle_info({:activity, json}, state) do
    {:push, {:text, json}, state}
  end

  @impl WebSock
  def handle_info(:pty_closed, state) do
    {:stop, :normal, state}
  end

  @impl WebSock
  def handle_info(_msg, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, _state) do
    DbMcp.Pty.unsubscribe(self())
    DbMcp.Activity.unsubscribe(self())
    :ok
  end
end

defmodule DbMcp.Web do
  @moduledoc false
  use Plug.Router

  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page_html())
  end

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(DbMcp.WsHandler, %{}, timeout: :infinity)
    |> halt()
  end

  get "/api/state" do
    pty_state = DbMcp.Pty.get_state()
    pending = DbMcp.Approval.get_pending()

    state = %{
      connected: pty_state.connected,
      connection:
        if pty_state.connected do
          %{
            name: pty_state.name,
            database: pty_state.metadata.database,
            host: pty_state.metadata.host,
            port: pty_state.metadata.port,
            user: pty_state.metadata.user
          }
        else
          nil
        end,
      pending:
        if pending do
          %{
            id: pending.id,
            sql: pending.sql,
            description: pending.description,
            connection: pending.connection_name,
            submitted_at: pending.submitted_at
          }
        else
          nil
        end
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(state))
  end

  post "/api/approve/:id" do
    DbMcp.Approval.respond(id, :approve)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "approved"}))
  end

  post "/api/reject/:id" do
    DbMcp.Approval.respond(id, :reject)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "rejected"}))
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp page_html do
    ~S"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>DB</title>
      <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5/css/xterm.css">
      <script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5/lib/xterm.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10/lib/addon-fit.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-web-links@0.11/lib/addon-web-links.js"></script>
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body { height: 100%; overflow: hidden; }
        body {
          background: #1e1e2e; color: #cdd6f4;
          font-family: 'SF Mono', 'Fira Code', 'JetBrains Mono', monospace;
          font-size: 14px; display: flex; flex-direction: column;
        }

        /* Header */
        #header {
          background: #181825; border-bottom: 1px solid #313244;
          padding: 8px 16px; display: flex; align-items: center; gap: 16px;
          flex-shrink: 0;
        }
        #header h1 { color: #89b4fa; font-size: 15px; white-space: nowrap; }
        #connection { display: flex; align-items: center; gap: 16px; }
        .conn-field { display: flex; align-items: baseline; gap: 4px; }
        .conn-label { color: #6c7086; font-size: 10px; text-transform: uppercase; }
        .conn-value { color: #a6e3a1; font-size: 12px; }
        .conn-sep { color: #313244; margin: 0 2px; }
        .disconnected { color: #f38ba8; font-size: 12px; }
        .status-dot {
          display: inline-block; width: 8px; height: 8px;
          border-radius: 50%; flex-shrink: 0;
        }
        .status-dot.on { background: #a6e3a1; }
        .status-dot.off { background: #f38ba8; }

        /* Approval banner */
        #approval {
          background: #181825; border-bottom: 2px solid #fab387;
          padding: 12px 16px; flex-shrink: 0; display: none;
          animation: pulse-border 2s ease-in-out infinite;
        }
        @keyframes pulse-border {
          0%, 100% { border-bottom-color: #fab387; }
          50% { border-bottom-color: #f38ba8; }
        }
        #approval .label {
          color: #fab387; font-size: 11px; text-transform: uppercase;
          letter-spacing: 1px; margin-bottom: 6px;
        }
        #approval .description {
          color: #6c7086; font-style: italic; margin-bottom: 8px; font-size: 12px;
        }
        #approval .conn-tag {
          color: #cba6f7; font-size: 11px; margin-bottom: 6px;
        }
        #approval .sql {
          background: #11111b; color: #f9e2af; padding: 8px 12px;
          border-radius: 4px; margin-bottom: 10px;
          white-space: pre-wrap; word-break: break-word;
          max-height: 200px; overflow-y: auto; font-size: 13px;
          border: 1px solid #fab387;
        }
        .btn-row { display: flex; gap: 10px; }
        .btn {
          padding: 8px 28px; border: none; border-radius: 4px;
          font-family: inherit; font-size: 13px; font-weight: bold;
          cursor: pointer;
        }
        .btn:hover { opacity: 0.85; }
        .btn:disabled { opacity: 0.4; cursor: not-allowed; }
        .btn-approve { background: #a6e3a1; color: #1e1e2e; }
        .btn-reject { background: #f38ba8; color: #1e1e2e; }

        /* Main panes */
        #main { display: flex; flex: 1; overflow: hidden; }
        #terminal-container { flex: 1; padding: 4px; overflow: hidden; }
        #terminal-container .xterm { height: 100%; }

        /* Activity pane */
        #activity-pane {
          width: 420px; flex-shrink: 0;
          border-left: 1px solid #313244; background: #181825;
          display: flex; flex-direction: column; overflow: hidden;
        }
        #activity-header {
          padding: 8px 12px; border-bottom: 1px solid #313244;
          font-size: 11px; color: #6c7086; text-transform: uppercase;
          letter-spacing: 0.5px; flex-shrink: 0;
        }
        #activity-log {
          flex: 1; overflow-y: auto; padding: 8px;
          display: flex; flex-direction: column; gap: 8px;
        }
        .activity-event {
          background: #1e1e2e; border: 1px solid #313244;
          border-radius: 6px; padding: 8px 10px; font-size: 12px;
        }
        .activity-event.error { border-color: #f38ba8; }
        .activity-event.approved { border-color: #a6e3a1; }
        .activity-event.rejected { border-color: #fab387; }
        .activity-meta {
          display: flex; justify-content: space-between; align-items: center;
          margin-bottom: 6px;
        }
        .activity-tool {
          font-size: 10px; padding: 2px 6px; border-radius: 3px;
          background: #313244; color: #89b4fa;
        }
        .activity-time { font-size: 10px; color: #585b70; }
        .activity-sql {
          background: #11111b; padding: 6px 8px; border-radius: 4px;
          font-size: 11px; color: #cdd6f4; white-space: pre-wrap;
          word-break: break-all; max-height: 80px; overflow-y: auto;
          margin-bottom: 6px;
        }
        .activity-result {
          background: #11111b; padding: 6px 8px; border-radius: 4px;
          font-size: 11px; color: #a6adc8; white-space: pre-wrap;
          word-break: break-all; max-height: 200px; overflow-y: auto;
        }
      </style>
    </head>
    <body>
      <div id="header">
        <h1>DB</h1>
        <div id="connection"><span class="status-dot off"></span><span class="disconnected">Not connected</span></div>
      </div>

      <div id="approval">
        <div class="label">Write Query — Pending Approval</div>
        <div id="approval-conn" class="conn-tag"></div>
        <div id="approval-desc" class="description"></div>
        <div id="approval-sql" class="sql"></div>
        <div class="btn-row">
          <button class="btn btn-approve" id="btn-approve">Execute</button>
          <button class="btn btn-reject" id="btn-reject">Reject</button>
        </div>
      </div>

      <div id="main">
        <div id="terminal-container"></div>
        <div id="activity-pane">
          <div id="activity-header">Agent Activity</div>
          <div id="activity-log"></div>
        </div>
      </div>

      <script>
        // --- Terminal setup ---
        const term = new Terminal({
          cursorBlink: true,
          fontSize: 14,
          fontFamily: "'SF Mono', 'Fira Code', 'JetBrains Mono', monospace",
          theme: {
            background: '#1e1e2e',
            foreground: '#cdd6f4',
            cursor: '#f5e0dc',
            selectionBackground: '#585b7066',
            black: '#45475a',
            red: '#f38ba8',
            green: '#a6e3a1',
            yellow: '#f9e2af',
            blue: '#89b4fa',
            magenta: '#cba6f7',
            cyan: '#94e2d5',
            white: '#bac2de',
            brightBlack: '#585b70',
            brightRed: '#f38ba8',
            brightGreen: '#a6e3a1',
            brightYellow: '#f9e2af',
            brightBlue: '#89b4fa',
            brightMagenta: '#cba6f7',
            brightCyan: '#94e2d5',
            brightWhite: '#a6adc8'
          }
        });

        const fitAddon = new FitAddon.FitAddon();
        const webLinksAddon = new WebLinksAddon.WebLinksAddon();
        term.loadAddon(fitAddon);
        term.loadAddon(webLinksAddon);
        term.open(document.getElementById('terminal-container'));
        fitAddon.fit();

        // --- WebSocket ---
        let ws = null;
        let reconnectTimer = null;

        function connectWs() {
          const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
          ws = new WebSocket(`${proto}//${location.host}/ws`);
          ws.binaryType = 'arraybuffer';

          ws.onopen = () => {
            term.focus();
            sendResize();
          };

          ws.onmessage = (event) => {
            if (event.data instanceof ArrayBuffer) {
              term.write(new Uint8Array(event.data));
            } else if (typeof event.data === 'string') {
              try {
                const msg = JSON.parse(event.data);
                if (msg.type === 'activity') addActivityEvent(msg.event);
              } catch (e) {}
            }
          };

          ws.onclose = () => {
            if (!reconnectTimer) {
              reconnectTimer = setTimeout(() => {
                reconnectTimer = null;
                connectWs();
              }, 2000);
            }
          };
        }

        term.onData(data => {
          if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(new TextEncoder().encode(data));
          }
        });

        function sendResize() {
          if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows }));
          }
        }

        window.addEventListener('resize', () => { fitAddon.fit(); sendResize(); });

        const resizeObserver = new ResizeObserver(() => { fitAddon.fit(); sendResize(); });
        resizeObserver.observe(document.getElementById('terminal-container'));

        connectWs();

        // --- Activity pane ---
        const activityLog = document.getElementById('activity-log');

        function addActivityEvent(ev) {
          const el = document.createElement('div');
          el.className = 'activity-event' + (ev.status === 'error' ? ' error' : ev.status === 'approved' ? ' approved' : ev.status === 'rejected' ? ' rejected' : '');

          const time = new Date(ev.at).toLocaleTimeString();
          const sql = ev.sql.length > 500 ? ev.sql.slice(0, 500) + '...' : ev.sql;
          const result = (ev.result || '').length > 2000 ? ev.result.slice(0, 2000) + '...' : (ev.result || '');

          el.innerHTML = `
            <div class="activity-meta">
              <span class="activity-tool">${ev.tool}</span>
              <span class="activity-time">${time}</span>
            </div>
            <div class="activity-sql">${escapeHtml(sql)}</div>
            <div class="activity-result">${escapeHtml(result)}</div>
          `;

          activityLog.appendChild(el);
          activityLog.scrollTop = activityLog.scrollHeight;
        }

        function escapeHtml(text) {
          const div = document.createElement('div');
          div.textContent = text;
          return div.innerHTML;
        }

        // --- State polling ---
        let currentPendingId = null;

        async function poll() {
          try {
            const resp = await fetch('/api/state');
            const state = await resp.json();
            renderConnection(state);
            renderApproval(state);
          } catch (e) {
            console.error('Poll error:', e);
          }
        }

        function renderConnection(state) {
          const el = document.getElementById('connection');
          if (!state.connected) {
            el.innerHTML = '<span class="status-dot off"></span><span class="disconnected">Not connected — use Claude to connect</span>';
            return;
          }
          const c = state.connection;
          el.innerHTML = `
            <span class="status-dot on"></span>
            <div class="conn-field"><span class="conn-label">conn:</span><span class="conn-value">${esc(c.name)}</span></div>
            <span class="conn-sep">/</span>
            <div class="conn-field"><span class="conn-label">db:</span><span class="conn-value">${esc(c.database)}</span></div>
            <span class="conn-sep">@</span>
            <div class="conn-field"><span class="conn-value">${esc(c.host)}:${esc(String.valueOf(c.port))}</span></div>
            <span class="conn-sep">as</span>
            <div class="conn-field"><span class="conn-value">${esc(c.user)}</span></div>
          `;
        }

        function renderApproval(state) {
          const el = document.getElementById('approval');
          if (!state.pending) {
            el.style.display = 'none';
            currentPendingId = null;
            return;
          }
          if (currentPendingId === state.pending.id) return;
          currentPendingId = state.pending.id;
          el.style.display = 'block';
          document.getElementById('approval-conn').textContent = `connection: ${state.pending.connection}`;
          document.getElementById('approval-desc').textContent = state.pending.description || '';
          document.getElementById('approval-sql').textContent = state.pending.sql;
          document.getElementById('btn-approve').disabled = false;
          document.getElementById('btn-reject').disabled = false;
          setTimeout(() => { fitAddon.fit(); sendResize(); }, 50);
        }

        document.getElementById('btn-approve').addEventListener('click', async () => {
          if (!currentPendingId) return;
          document.getElementById('btn-approve').disabled = true;
          document.getElementById('btn-reject').disabled = true;
          await fetch(`/api/approve/${currentPendingId}`, { method: 'POST' });
          setTimeout(poll, 300);
        });

        document.getElementById('btn-reject').addEventListener('click', async () => {
          if (!currentPendingId) return;
          document.getElementById('btn-approve').disabled = true;
          document.getElementById('btn-reject').disabled = true;
          await fetch(`/api/reject/${currentPendingId}`, { method: 'POST' });
          setTimeout(poll, 300);
        });

        function esc(s) {
          if (s == null) return '';
          const d = document.createElement('div');
          d.textContent = String(s);
          return d.innerHTML;
        }

        setInterval(poll, 2000);
        poll();
      </script>
    </body>
    </html>
    """
  end
end

defmodule DbMcp.Connection do
  @moduledoc false

  use GenServer

  # State: %{connections: %{name => %{pool: pid, metadata: map}}}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def connect(vault_id, item_name, name) do
    GenServer.call(__MODULE__, {:connect, vault_id, item_name, name}, 30_000)
  end

  def connect_local(creds, name) do
    GenServer.call(__MODULE__, {:connect_local, creds, name}, 30_000)
  end

  def disconnect(name) do
    GenServer.call(__MODULE__, {:disconnect, name})
  end

  def disconnect_all do
    GenServer.call(__MODULE__, :disconnect_all)
  end

  def status(name) do
    GenServer.call(__MODULE__, {:status, name})
  end

  def status_all do
    GenServer.call(__MODULE__, :status_all)
  end

  def list_connections do
    GenServer.call(__MODULE__, :list_connections)
  end

  def query(name, sql, opts \\ %{}) do
    GenServer.call(__MODULE__, {:query, name, sql, opts}, 120_000)
  end

  def execute(name, sql) do
    GenServer.call(__MODULE__, {:execute, name, sql}, 120_000)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{connections: %{}}}
  end

  @impl GenServer
  def handle_call({:connect, vault_id, item_name, name}, _from, %{connections: conns} = state) do
    case Map.get(conns, name) do
      %{pool: old_pool} -> GenServer.stop(old_pool, :normal, 5_000)
      nil -> :ok
    end

    case DbMcp.Credentials.fetch(vault_id, item_name) do
      {:ok, creds} ->
        ctx = %{
          host: creds.hostname,
          port: creds.port,
          user: creds.username,
          database: creds.database,
          ssl: true,
          source: "1Password #{vault_id}/#{item_name}"
        }

        pool_opts = [
          hostname: creds.hostname,
          port: creds.port,
          username: creds.username,
          password: creds.password,
          database: creds.database,
          ssl: [verify: :verify_none],
          pool_size: 2,
          connect_timeout: 10_000,
          queue_target: 5_000,
          queue_interval: 1_000,
          json_library: Jason
        ]

        do_connect(name, creds, pool_opts, ctx, conns, state)

      {:error, reason} ->
        new_conns = Map.delete(conns, name)
        {:reply, {:error, reason}, %{state | connections: new_conns}}
    end
  end

  @impl GenServer
  def handle_call({:connect_local, creds, name}, _from, %{connections: conns} = state) do
    case Map.get(conns, name) do
      %{pool: old_pool} -> GenServer.stop(old_pool, :normal, 5_000)
      nil -> :ok
    end

    # hostname is always localhost — cannot be overridden
    resolved = %{creds | hostname: "localhost"}

    ctx = %{
      host: "localhost",
      port: resolved.port,
      user: resolved.username,
      database: resolved.database,
      ssl: false,
      source: "local connection"
    }

    pool_opts = [
      hostname: "localhost",
      port: resolved.port,
      username: resolved.username,
      password: resolved.password,
      database: resolved.database,
      pool_size: 2,
      connect_timeout: 10_000,
      queue_target: 5_000,
      queue_interval: 1_000,
      json_library: Jason
    ]

    do_connect(name, resolved, pool_opts, ctx, conns, state)
  end

  def handle_call({:disconnect, name}, _from, %{connections: conns} = state) do
    case Map.get(conns, name) do
      %{pool: pool} ->
        GenServer.stop(pool, :normal, 5_000)
        DbMcp.Pty.disconnect(name)
        DbMcp.Log.info("Disconnected '#{name}'")

        {:reply, {:ok, "Disconnected '#{name}'."},
         %{state | connections: Map.delete(conns, name)}}

      nil ->
        {:reply, {:error, "No connection named '#{name}'."}, state}
    end
  end

  def handle_call(:disconnect_all, _from, %{connections: conns} = state) do
    Enum.each(conns, fn {name, %{pool: pool}} ->
      GenServer.stop(pool, :normal, 5_000)
      DbMcp.Pty.disconnect(name)
    end)

    names = Map.keys(conns) |> Enum.join(", ")
    DbMcp.Log.info("Disconnected all: #{names}")

    {:reply, {:ok, "Disconnected all connections (#{names})."}, %{state | connections: %{}}}
  end

  def handle_call(:list_connections, _from, %{connections: conns} = state) do
    {:reply, {:ok, Map.keys(conns)}, state}
  end

  def handle_call({:status, name}, _from, %{connections: conns} = state) do
    case Map.get(conns, name) do
      %{pool: pool, metadata: meta} ->
        pool_alive = Process.alive?(pool)

        info =
          "Connection: #{name}\n" <>
            "Database: #{meta.database}\n" <>
            "Host: #{meta.host}:#{meta.port}\n" <>
            "User: #{meta.user}\n" <>
            "PostgreSQL: #{meta.pg_version}\n" <>
            "Pool: #{if pool_alive, do: "healthy", else: "unhealthy"}\n" <>
            "Web UI: http://localhost:#{DbMcp.Server.web_port()}"

        {:reply, {:ok, info}, state}

      nil ->
        {:reply, {:error, "No connection named '#{name}'."}, state}
    end
  end

  def handle_call(:status_all, _from, %{connections: conns} = state) when map_size(conns) == 0 do
    {:reply, {:error, "No active connections. Use 'pg_connect' to connect."}, state}
  end

  def handle_call(:status_all, _from, %{connections: conns} = state) do
    info =
      conns
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, %{pool: pool, metadata: meta}} ->
        pool_alive = Process.alive?(pool)
        status = if pool_alive, do: "healthy", else: "unhealthy"
        "- **#{name}**: #{meta.database} on #{meta.host}:#{meta.port} as #{meta.user} [#{status}]"
      end)
      |> Enum.join("\n")

    {:reply, {:ok, "Active connections:\n#{info}"}, state}
  end

  def handle_call({:query, name, sql, opts}, _from, %{connections: conns} = state) do
    case Map.get(conns, name) do
      nil ->
        {:reply, {:error, no_connection_error(name, conns)}, state}

      %{pool: pool, metadata: meta} ->
        case DbMcp.SQL.validate_read_only(sql) do
          :ok ->
            start_time = System.monotonic_time(:millisecond)

            result =
              Postgrex.transaction(pool, fn conn ->
                with {:ok, _} <- Postgrex.query(conn, "SET TRANSACTION READ ONLY", []),
                     {:ok, query_result} <- Postgrex.query(conn, sql, []) do
                  query_result
                else
                  {:error, err} -> DBConnection.rollback(conn, err)
                end
              end)

            elapsed = System.monotonic_time(:millisecond) - start_time

            case result do
              {:ok, %Postgrex.Result{} = res} ->
                formatted = DbMcp.Format.format_results(res, opts)
                {:reply, {:ok, "[#{name}] #{formatted}\n\nQuery time: #{elapsed}ms"}, state}

              {:error, reason} ->
                {:reply, {:error, humanize_query_error(name, reason, meta)}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:execute, name, sql}, _from, %{connections: conns} = state) do
    case Map.get(conns, name) do
      nil ->
        {:reply, {:error, no_connection_error(name, conns)}, state}

      %{pool: pool, metadata: meta} ->
        start_time = System.monotonic_time(:millisecond)

        case Postgrex.query(pool, sql, []) do
          {:ok, %Postgrex.Result{} = res} ->
            elapsed = System.monotonic_time(:millisecond) - start_time
            formatted = DbMcp.Format.format_write_result(res)
            {:reply, {:ok, "[#{name}] #{formatted}\n\nExecution time: #{elapsed}ms"}, state}

          {:error, reason} ->
            {:reply, {:error, humanize_query_error(name, reason, meta) |> String.replace("Query failed", "Execution failed")},
             state}
        end
    end
  end

  defp do_connect(name, creds, pool_opts, ctx, conns, state) do
    case tcp_probe(ctx.host, ctx.port) do
      :ok ->
        do_start_pool(name, creds, pool_opts, ctx, conns, state)

      {:error, reason} ->
        new_conns = Map.delete(conns, name)
        DbMcp.Log.error("TCP probe failed for '#{name}': #{inspect(reason)}")

        {:reply, {:error, humanize_tcp_error(reason, ctx)},
         %{state | connections: new_conns}}
    end
  end

  # Sync TCP reach-check so callers get the real socket error (econnrefused,
  # nxdomain, timeout, …) instead of DBConnection's generic "queue dropped"
  # message that surfaces after Postgrex's async retries time out.
  defp tcp_probe(host, port) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 5_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp humanize_tcp_error(reason, %{host: host, port: port}) do
    detail =
      case reason do
        :nxdomain ->
          "DNS lookup failed for '#{host}'. " <>
            "Check the hostname is correct, that DNS is reachable, and (if applicable) " <>
            "that you are on the right VPN."

        :econnrefused ->
          "Connection refused at #{host}:#{port}. " <>
            "Is PostgreSQL running and listening on that port? " <>
            "If using an SSH tunnel, verify the tunnel is up."

        r when r in [:timeout, :etimedout] ->
          "Connection timed out to #{host}:#{port}. " <>
            "The host is unreachable from this machine — check network/VPN, firewall, and " <>
            "security-group rules."

        :ehostunreach ->
          "Host '#{host}' is unreachable from this network. VPN connected?"

        :enetunreach ->
          "Network unreachable to #{host}:#{port}. VPN/route missing?"

        :econnreset ->
          "Connection reset by peer at #{host}:#{port}."

        :eaddrnotavail ->
          "Local address not available — interface down?"

        other ->
          "Socket error: #{inspect(other)}"
      end

    "Could not reach PostgreSQL at #{host}:#{port}.\n  " <> detail
  end

  defp do_start_pool(name, creds, pool_opts, ctx, conns, state) do
    case Postgrex.start_link(pool_opts) do
      {:ok, pool} ->
        case verify_connection(pool) do
          {:ok, meta} ->
            DbMcp.Pty.connect(name, creds)

            conn_info = %{
              pool: pool,
              metadata: %{
                host: ctx.host,
                port: ctx.port,
                user: ctx.user,
                database: ctx.database,
                pg_version: meta.pg_version
              }
            }

            msg =
              "Connected '#{name}' to '#{ctx.database}' on #{ctx.host}:#{ctx.port} " <>
                "as '#{ctx.user}' (#{meta.pg_version})\n" <>
                "Web UI: http://localhost:#{DbMcp.Server.web_port()}"

            DbMcp.Log.info(msg)
            new_conns = Map.put(conns, name, conn_info)
            {:reply, {:ok, msg}, %{state | connections: new_conns}}

          {:error, reason} ->
            GenServer.stop(pool, :normal, 5_000)
            new_conns = Map.delete(conns, name)
            DbMcp.Log.error("Connection '#{name}' failed verification: #{inspect(reason)}")

            {:reply, {:error, humanize_connect_error(reason, ctx)},
             %{state | connections: new_conns}}
        end

      {:error, reason} ->
        new_conns = Map.delete(conns, name)
        DbMcp.Log.error("Pool start_link failed for '#{name}': #{inspect(reason)}")

        {:reply, {:error, humanize_connect_error(reason, ctx)},
         %{state | connections: new_conns}}
    end
  end

  defp verify_connection(pool) do
    # Bound the probe so an unreachable host fails fast instead of hanging on
    # Postgrex's internal retries.
    case Postgrex.query(pool, "SELECT current_database(), current_user, version()", [],
           timeout: 10_000
         ) do
      {:ok, %Postgrex.Result{rows: [[_db, _user, version]]}} ->
        pg_version =
          case Regex.run(~r/PostgreSQL [\d.]+/, version) do
            [match] -> match
            _ -> version
          end

        {:ok, %{pg_version: pg_version}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  catch
    kind, payload -> {:error, {kind, payload}}
  end

  # Turn a raw Postgrex / DBConnection failure into a multi-line, actionable
  # message that names the host/port/user/database the caller was reaching for.
  defp humanize_connect_error(reason, ctx) do
    %{host: host, port: port, user: user, database: db} = ctx
    header = "Could not connect to PostgreSQL at #{host}:#{port} (database '#{db}', user '#{user}')."

    detail =
      case reason do
        %DBConnection.ConnectionError{message: msg} ->
          classify_socket_message(msg, ctx)

        %Postgrex.Error{postgres: %{code: :invalid_password}} ->
          "Authentication failed for user '#{user}'. " <>
            "Verify the password matches what the server expects " <>
            "(source: #{Map.get(ctx, :source, "credential lookup")})."

        %Postgrex.Error{postgres: %{code: :invalid_authorization_specification, message: msg}} ->
          "Authorization rejected: #{msg}. Check the username/password and pg_hba.conf rules."

        %Postgrex.Error{postgres: %{code: :invalid_catalog_name}} ->
          "Database '#{db}' does not exist on #{host}:#{port}. " <>
            "List databases with `\\l` in psql or fix the credential entry."

        %Postgrex.Error{postgres: %{code: code, message: msg}} ->
          "PostgreSQL error (#{code}): #{msg}"

        %Postgrex.Error{message: msg} when is_binary(msg) ->
          msg

        {:tcp, :econnrefused} ->
          classify_socket_message("econnrefused", ctx)

        {:tcp, :timeout} ->
          classify_socket_message("timeout", ctx)

        {:exit, {:shutdown, sub}} ->
          "Pool shut down before it could connect: #{inspect(sub)}."

        :killed ->
          "Connection process was killed before it could be verified."

        other ->
          "Unexpected error: #{inspect(other)}"
      end

    header <> "\n  " <> detail
  end

  defp classify_socket_message(msg, %{host: host, port: port} = ctx) when is_binary(msg) do
    cond do
      msg =~ "nxdomain" ->
        "DNS lookup failed for '#{host}'. " <>
          "Check the hostname is correct, that DNS is reachable, and (if applicable) " <>
          "that you are on the right VPN."

      msg =~ "econnrefused" or msg =~ "connection refused" ->
        "Connection refused at #{host}:#{port}. " <>
          "Is PostgreSQL running and listening on that port? " <>
          "If using an SSH tunnel, verify the tunnel is up."

      msg =~ "timeout" or msg =~ "etimedout" ->
        "Connection timed out to #{host}:#{port}. " <>
          "The host is unreachable from this machine — check network/VPN, firewall, and " <>
          "security-group rules."

      msg =~ "ehostunreach" ->
        "Host '#{host}' is unreachable from this network. VPN connected?"

      msg =~ "enetunreach" ->
        "Network unreachable to #{host}:#{port}. VPN/route missing?"

      msg =~ "closed" ->
        ssl_hint =
          if Map.get(ctx, :ssl, false),
            do: "",
            else: " The server may require SSL — try `pg_connect` (1Password) instead of local."

        "Connection closed by the server during handshake.#{ssl_hint}"

      msg =~ "tls" or msg =~ "ssl" ->
        ssl_hint =
          if Map.get(ctx, :ssl, false),
            do: " The server may not support SSL — try `pg_connect_local`.",
            else: " The server may require SSL — try `pg_connect` instead of local."

        "TLS/SSL handshake failed: #{msg}.#{ssl_hint}"

      true ->
        msg
    end
  end

  defp classify_socket_message(other, _ctx), do: inspect(other)

  defp humanize_query_error(name, reason, meta) do
    case reason do
      %DBConnection.ConnectionError{message: msg} ->
        ctx = %{
          host: meta.host,
          port: meta.port,
          user: meta.user,
          database: meta.database,
          ssl: false
        }

        "[#{name}] Lost connection to #{meta.host}:#{meta.port}.\n  " <>
          classify_socket_message(msg, ctx)

      %Postgrex.Error{postgres: %{message: msg, code: code}} ->
        "[#{name}] Query failed (#{code}): #{msg}"

      %Postgrex.Error{postgres: %{message: msg}} ->
        "[#{name}] Query failed: #{msg}"

      other ->
        "[#{name}] Query failed: #{inspect(other)}"
    end
  end

  defp no_connection_error(_name, conns) when map_size(conns) == 0 do
    "No active connections. Use 'pg_connect' to connect first."
  end

  defp no_connection_error(name, conns) do
    available = Map.keys(conns) |> Enum.join(", ")
    "No connection named '#{name}'. Available: #{available}"
  end
end

defmodule DbMcp.Tools do
  @moduledoc false

  @connection_prop %{
    "type" => "string",
    "description" =>
      "Connection name to use. If omitted and only one connection exists, it is used automatically. " <>
        "Required when multiple connections are active."
  }

  def definitions do
    [
      %{
        "name" => "pg_connect",
        "description" =>
          "Connect to a PostgreSQL database using credentials from 1Password. " <>
            "Starts both a Postgrex connection pool (for Claude's queries) and an interactive " <>
            "psql terminal in the browser. " <>
            "Open http://localhost:#{DbMcp.Server.web_port()} to access the terminal.",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["vault_id", "item_name"],
          "properties" => %{
            "vault_id" => %{
              "type" => "string",
              "description" =>
                "The 1Password vault ID (not name) containing the database credentials"
            },
            "item_name" => %{
              "type" => "string",
              "description" => "The 1Password item name containing the database credentials"
            },
            "name" => %{
              "type" => "string",
              "description" =>
                "A short name for this connection (e.g. 'prod', 'staging'). " <>
                  "Defaults to the database name from the credentials."
            }
          }
        }
      },
      %{
        "name" => "pg_connect_local",
        "description" =>
          "Connect to a local PostgreSQL database (localhost only) using explicit credentials. " <>
            "Host is always localhost — use this for local dev databases. " <>
            "For remote databases, use 'pg_connect' with 1Password credentials instead. " <>
            "Starts both a Postgrex connection pool and an interactive psql terminal in the browser. " <>
            "Open http://localhost:#{DbMcp.Server.web_port()} to access the terminal.",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["port", "username", "password", "database"],
          "properties" => %{
            "port" => %{
              "type" => "integer",
              "description" => "PostgreSQL port (typically 5432)"
            },
            "username" => %{
              "type" => "string",
              "description" => "Database username"
            },
            "password" => %{
              "type" => "string",
              "description" => "Database password"
            },
            "database" => %{
              "type" => "string",
              "description" => "Database name to connect to"
            },
            "name" => %{
              "type" => "string",
              "description" =>
                "A short name for this connection (e.g. 'local', 'dev'). " <>
                  "Defaults to the database name."
            }
          }
        }
      },
      %{
        "name" => "pg_disconnect",
        "description" =>
          "Close a PostgreSQL database connection and its psql terminal. " <>
            "Omit 'connection' to disconnect all.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "connection" => @connection_prop
          }
        }
      },
      %{
        "name" => "pg_status",
        "description" =>
          "Show PostgreSQL connection info including host, database, user, " <>
            "version, and pool health. Never reveals passwords. " <>
            "Omit 'connection' to show all connections.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "connection" => @connection_prop
          }
        }
      },
      %{
        "name" => "pg_query",
        "description" =>
          "Execute a read-only SQL query against a connected PostgreSQL database. " <>
            "Write operations (INSERT, UPDATE, DELETE, etc.) are blocked — use 'pg_submit_write' instead. " <>
            "Results are formatted as a markdown table by default.",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["sql"],
          "properties" => %{
            "sql" => %{
              "type" => "string",
              "description" => "The SQL query to execute (SELECT only)"
            },
            "connection" => @connection_prop,
            "limit" => %{
              "type" => "integer",
              "description" => "Maximum rows to return (default 100, max 1000)",
              "default" => 100,
              "maximum" => 1000
            },
            "format" => %{
              "type" => "string",
              "enum" => ["table", "json", "csv"],
              "description" =>
                "Output format: 'table' (markdown), 'json', or 'csv'. Default: 'table'",
              "default" => "table"
            }
          }
        }
      },
      %{
        "name" => "pg_submit_write",
        "description" =>
          "Submit a write SQL query (INSERT, UPDATE, DELETE, DDL) for approval. " <>
            "This tool BLOCKS until the user approves or rejects the query in the web UI at " <>
            "http://localhost:#{DbMcp.Server.web_port()}. " <>
            "On approval, the query executes immediately and the result is returned. " <>
            "On rejection, the query is NOT executed.",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["sql"],
          "properties" => %{
            "sql" => %{
              "type" => "string",
              "description" => "The SQL write query to execute after approval"
            },
            "connection" => @connection_prop,
            "description" => %{
              "type" => "string",
              "description" =>
                "Brief description of what this query does, shown in the approval UI"
            }
          }
        }
      },
      %{
        "name" => "session_history",
        "description" =>
          "Read recent output from the psql terminal session. " <>
            "Useful for seeing what the user has been doing interactively.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "lines" => %{
              "type" => "integer",
              "description" => "Number of recent lines to return (default 100, max 500)"
            }
          }
        }
      },
      %{
        "name" => "search_history",
        "description" =>
          "Search the psql terminal scrollback for a specific term. " <>
            "Returns matching lines with surrounding context.",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "Text to search for (case-insensitive)"
            }
          }
        }
      }
    ]
  end

  def call("pg_connect", %{"vault_id" => vault_id, "item_name" => item_name} = params) do
    explicit_name = Map.get(params, "name")

    if explicit_name do
      do_connect(vault_id, item_name, explicit_name)
    else
      case DbMcp.Credentials.fetch(vault_id, item_name) do
        {:ok, creds} ->
          do_connect(vault_id, item_name, creds.database)

        {:error, reason} ->
          tool_error(reason)
      end
    end
  end

  def call("pg_connect", _params) do
    tool_error("Missing required parameters: 'vault_id' and 'item_name'")
  end

  def call(
        "pg_connect_local",
        %{"port" => port, "username" => username, "password" => password, "database" => database} =
          params
      ) do
    name = Map.get(params, "name", database)

    creds = %{
      hostname: "localhost",
      port: if(is_integer(port), do: port, else: String.to_integer(to_string(port))),
      username: username,
      password: password,
      database: database
    }

    case DbMcp.Connection.connect_local(creds, name) do
      {:ok, msg} -> tool_result(msg)
      {:error, reason} -> tool_error(reason)
    end
  end

  def call("pg_connect_local", _params) do
    tool_error("Missing required parameters: 'port', 'username', 'password', and 'database'")
  end

  def call("pg_disconnect", params) do
    case Map.get(params, "connection") do
      nil ->
        case DbMcp.Connection.disconnect_all() do
          {:ok, msg} -> tool_result(msg)
          {:error, reason} -> tool_error(reason)
        end

      name ->
        case DbMcp.Connection.disconnect(name) do
          {:ok, msg} -> tool_result(msg)
          {:error, reason} -> tool_error(reason)
        end
    end
  end

  def call("pg_status", params) do
    case Map.get(params, "connection") do
      nil ->
        case DbMcp.Connection.status_all() do
          {:ok, info} -> tool_result(info)
          {:error, reason} -> tool_error(reason)
        end

      name ->
        case DbMcp.Connection.status(name) do
          {:ok, info} -> tool_result(info)
          {:error, reason} -> tool_error(reason)
        end
    end
  end

  def call("pg_query", %{"sql" => sql} = params) do
    case resolve_connection(params) do
      {:ok, name} ->
        case DbMcp.Connection.query(name, sql, params) do
          {:ok, result} ->
            DbMcp.Activity.push("pg_query", sql, result, :ok)
            tool_result(result)

          {:error, reason} ->
            DbMcp.Activity.push("pg_query", sql, reason, :error)
            tool_error(reason)
        end

      {:error, reason} ->
        tool_error(reason)
    end
  end

  def call("pg_query", _params) do
    tool_error("Missing required parameter: 'sql'")
  end

  def call("pg_submit_write", %{"sql" => sql} = params) do
    case resolve_connection(params) do
      {:ok, name} ->
        description = Map.get(params, "description", "")

        case DbMcp.Approval.submit_and_wait(sql, description, name) do
          :approve ->
            case DbMcp.Connection.execute(name, sql) do
              {:ok, result} ->
                DbMcp.Activity.push("pg_submit_write", sql, result, :approved)
                tool_result("(Approved)\n\n#{result}")

              {:error, reason} ->
                DbMcp.Activity.push("pg_submit_write", sql, reason, :error)
                tool_error("(Approved but failed to execute)\n\n#{reason}")
            end

          :reject ->
            DbMcp.Activity.push("pg_submit_write", sql, "Rejected", :rejected)
            tool_result("Rejected by user. Query was NOT executed.")

          {:error, reason} ->
            tool_error(reason)
        end

      {:error, reason} ->
        tool_error(reason)
    end
  end

  def call("pg_submit_write", _params) do
    tool_error("Missing required parameter: 'sql'")
  end

  def call("session_history", params) do
    lines = Map.get(params, "lines", 100) |> min(500)

    case DbMcp.Pty.get_scrollback(lines) do
      "" -> tool_result("No session history yet.")
      history -> tool_result(history)
    end
  end

  def call("search_history", %{"query" => query}) do
    case DbMcp.Pty.search_scrollback(query) do
      [] ->
        tool_result("No matches found for '#{query}'")

      matches ->
        results =
          matches
          |> Enum.take(20)
          |> Enum.map(fn m -> "--- Line #{m.line} ---\n#{m.context}" end)

        tool_result("Found #{length(matches)} match(es):\n\n#{Enum.join(results, "\n\n")}")
    end
  end

  def call(tool_name, _params) do
    tool_error("Unknown tool: #{tool_name}")
  end

  defp resolve_connection(params) do
    case Map.get(params, "connection") do
      name when is_binary(name) ->
        {:ok, name}

      nil ->
        case DbMcp.Connection.list_connections() do
          {:ok, []} ->
            {:error, "No active connections. Use 'pg_connect' to connect first."}

          {:ok, [single_name]} ->
            {:ok, single_name}

          {:ok, names} ->
            list = Enum.join(names, ", ")

            {:error,
             "Multiple connections active (#{list}). Specify which one with the 'connection' parameter."}
        end
    end
  end

  defp do_connect(vault_id, item_name, name) do
    case DbMcp.Connection.connect(vault_id, item_name, name) do
      {:ok, msg} -> tool_result(msg)
      {:error, reason} -> tool_error(reason)
    end
  end

  defp tool_result(text) do
    %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}
  end

  defp tool_error(message) do
    %{"content" => [%{"type" => "text", "text" => "Error: #{message}"}], "isError" => true}
  end
end

defmodule DbMcp.Server do
  @moduledoc false

  @protocol_version "2025-11-25"
  @server_name "db-mcp"
  @server_version "2.0.0"

  def run do
    DbMcp.Log.info("Starting #{@server_name} v#{@server_version}")
    DbMcp.Log.info("Web UI: http://localhost:#{web_port()}")
    DbMcp.Log.info("MCP protocol version: #{@protocol_version}")
    DbMcp.Log.info("Server ready, waiting for input on stdin")
    loop()
  end

  def web_port, do: :persistent_term.get(:db_mcp_port, 0)

  defp loop do
    case IO.read(:stdio, :line) do
      :eof ->
        DbMcp.Log.info("Received EOF, shutting down")
        :ok

      {:error, reason} ->
        DbMcp.Log.error("Read error: #{inspect(reason)}")
        :ok

      line ->
        line
        |> String.trim()
        |> handle_line()

        loop()
    end
  end

  defp handle_line(""), do: :ok

  defp handle_line(line) do
    try do
      case JSON.decode(line) do
        {:ok, message} ->
          handle_message(message)

        {:error, _} ->
          send_error(nil, -32700, "Parse error: invalid JSON")
      end
    rescue
      e ->
        DbMcp.Log.error(
          "Unhandled exception: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        id =
          case JSON.decode(line) do
            {:ok, %{"id" => id}} -> id
            _ -> nil
          end

        send_error(id, -32603, "Internal error: #{Exception.message(e)}")
    end
  end

  defp handle_message(%{"jsonrpc" => "2.0", "method" => method, "id" => id} = msg) do
    params = Map.get(msg, "params", %{})
    DbMcp.Log.debug("Request: #{method} (id=#{inspect(id)})")

    case handle_request(method, params) do
      {:ok, result} -> send_response(id, result)
      {:error, code, message} -> send_error(id, code, message)
    end
  end

  defp handle_message(%{"jsonrpc" => "2.0", "method" => method} = msg) do
    params = Map.get(msg, "params", %{})
    DbMcp.Log.debug("Notification: #{method}")
    handle_notification(method, params)
  end

  defp handle_message(_) do
    send_error(nil, -32600, "Invalid request: not a valid JSON-RPC 2.0 message")
  end

  defp handle_request("initialize", _params) do
    result = %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{
        "name" => @server_name,
        "version" => @server_version,
        "webUi" => "http://localhost:#{web_port()}"
      }
    }

    {:ok, result}
  end

  defp handle_request("ping", _params), do: {:ok, %{}}
  defp handle_request("tools/list", _params), do: {:ok, %{"tools" => DbMcp.Tools.definitions()}}

  defp handle_request("tools/call", %{"name" => tool_name, "arguments" => arguments}) do
    result = DbMcp.Tools.call(tool_name, arguments)
    {:ok, result}
  end

  defp handle_request("tools/call", %{"name" => tool_name}) do
    result = DbMcp.Tools.call(tool_name, %{})
    {:ok, result}
  end

  defp handle_request("tools/call", _params) do
    {:error, -32602, "Invalid params: 'name' is required for tools/call"}
  end

  defp handle_request(method, _params) do
    {:error, -32601, "Method not found: #{method}"}
  end

  defp handle_notification("notifications/initialized", _params) do
    DbMcp.Log.info("Client initialized successfully")
    :ok
  end

  defp handle_notification("notifications/cancelled", %{"requestId" => req_id}) do
    DbMcp.Log.info("Client cancelled request: #{inspect(req_id)}")
    :ok
  end

  defp handle_notification(method, _params) do
    DbMcp.Log.debug("Unhandled notification: #{method}")
    :ok
  end

  defp send_response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    |> JSON.encode!()
    |> IO.puts()
  end

  defp send_error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
    |> JSON.encode!()
    |> IO.puts()
  end
end

# --- Entry Point ---
unless Code.ensure_loaded?(TestRunner) do
  Process.flag(:trap_exit, true)

  # Web UI port: honor DB_MCP_WEB_PORT if set; otherwise allocate a random free port.
  port =
    case System.get_env("DB_MCP_WEB_PORT") do
      nil ->
        {:ok, socket} = :gen_tcp.listen(0, [])
        {:ok, p} = :inet.port(socket)
        :gen_tcp.close(socket)
        p

      "" ->
        {:ok, socket} = :gen_tcp.listen(0, [])
        {:ok, p} = :inet.port(socket)
        :gen_tcp.close(socket)
        p

      val ->
        case Integer.parse(val) do
          {p, ""} when p >= 0 and p <= 65_535 ->
            p

          _ ->
            DbMcp.Log.error("Invalid DB_MCP_WEB_PORT=#{inspect(val)}; falling back to random port")

            {:ok, socket} = :gen_tcp.listen(0, [])
            {:ok, p} = :inet.port(socket)
            :gen_tcp.close(socket)
            p
        end
    end

  :persistent_term.put(:db_mcp_port, port)

  DbMcp.Pty.start_link()
  DbMcp.Activity.start_link()
  DbMcp.Approval.start_link()
  {:ok, _} = DbMcp.Connection.start_link([])

  {:ok, _} =
    Bandit.start_link(
      plug: DbMcp.Web,
      port: port,
      thousand_island_options: [num_acceptors: 2],
      startup_log: false
    )

  DbMcp.Server.run()
end
