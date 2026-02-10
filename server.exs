#!/usr/bin/env elixir

# DB MCP Server - PostgreSQL database access via MCP over stdio
#
# Provides persistent database connections through 1Password credential lookup.
# Supports multiple simultaneous named connections.
# Read queries execute instantly; write queries require two-step confirmation.
#
# Usage:
#   elixir server.exs

Mix.install([{:postgrex, "~> 0.19"}, {:jason, "~> 1.4"}, {:sql_parser, "~> 0.2.5"}])

defmodule DbMcp.Log do
  @moduledoc false

  def info(msg), do: IO.puts(:stderr, "[INFO] #{msg}")
  def error(msg), do: IO.puts(:stderr, "[ERROR] #{msg}")
  def debug(msg), do: IO.puts(:stderr, "[DEBUG] #{msg}")
end

defmodule DbMcp.Credentials do
  @moduledoc false

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

    case System.cmd("op", ["item", "get", item_name, "--vault", vault_id, "--format", "json"],
           stderr_to_stdout: false
         ) do
      {output, 0} ->
        parse_item(output)

      {error_output, _code} ->
        {:error, "1Password lookup failed: #{String.trim(error_output)}"}
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
        # Parser can't handle it — check the leading keyword as a fallback.
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

defmodule DbMcp.Writes do
  @moduledoc false

  use GenServer

  @table :pending_writes
  @ttl_seconds 300
  @cleanup_interval_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def submit(connection_name, sql, description) do
    GenServer.call(__MODULE__, {:submit, connection_name, sql, description})
  end

  def fetch(query_id) do
    GenServer.call(__MODULE__, {:fetch, query_id})
  end

  def purge_all do
    GenServer.call(__MODULE__, :purge_all)
  end

  def purge_connection(connection_name) do
    GenServer.call(__MODULE__, {:purge_connection, connection_name})
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:submit, connection_name, sql, description}, _from, state) do
    id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    now = System.system_time(:second)
    :ets.insert(@table, {id, connection_name, sql, description, now})
    {:reply, {:ok, id}, state}
  end

  def handle_call({:fetch, query_id}, _from, state) do
    now = System.system_time(:second)

    result =
      case :ets.lookup(@table, query_id) do
        [{^query_id, connection_name, sql, _description, submitted_at}] ->
          if now - submitted_at > @ttl_seconds do
            :ets.delete(@table, query_id)

            {:error,
             "Query '#{query_id}' has expired (submitted #{now - submitted_at}s ago, TTL is #{@ttl_seconds}s)"}
          else
            :ets.delete(@table, query_id)
            {:ok, connection_name, sql}
          end

        [] ->
          {:error, "Query '#{query_id}' not found. It may have already been executed or expired."}
      end

    {:reply, result, state}
  end

  def handle_call(:purge_all, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  def handle_call({:purge_connection, connection_name}, _from, state) do
    # Select IDs where connection_name matches
    ids =
      :ets.select(@table, [
        {{:"$1", connection_name, :_, :_, :_}, [], [:"$1"]}
      ])

    Enum.each(ids, &:ets.delete(@table, &1))
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)

    expired =
      :ets.select(@table, [
        {{:"$1", :_, :_, :_, :"$2"}, [{:<, :"$2", now - @ttl_seconds}], [:"$1"]}
      ])

    Enum.each(expired, &:ets.delete(@table, &1))

    if length(expired) > 0 do
      DbMcp.Log.debug("Cleaned up #{length(expired)} expired pending writes")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
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
    # If reconnecting to same name, stop old pool
    case Map.get(conns, name) do
      %{pool: old_pool} -> GenServer.stop(old_pool, :normal, 5_000)
      nil -> :ok
    end

    case DbMcp.Credentials.fetch(vault_id, item_name) do
      {:ok, creds} ->
        pool_opts = [
          hostname: creds.hostname,
          port: creds.port,
          username: creds.username,
          password: creds.password,
          database: creds.database,
          ssl: [verify: :verify_none],
          pool_size: 2,
          queue_target: 5_000,
          queue_interval: 1_000,
          json_library: Jason
        ]

        case Postgrex.start_link(pool_opts) do
          {:ok, pool} ->
            case verify_connection(pool) do
              {:ok, meta} ->
                conn_info = %{
                  pool: pool,
                  metadata: %{
                    host: creds.hostname,
                    port: creds.port,
                    user: creds.username,
                    database: creds.database,
                    pg_version: meta.pg_version
                  }
                }

                msg =
                  "Connected '#{name}' to '#{creds.database}' on #{creds.hostname}:#{creds.port} " <>
                    "as '#{creds.username}' (#{meta.pg_version})"

                DbMcp.Log.info(msg)
                new_conns = Map.put(conns, name, conn_info)
                {:reply, {:ok, msg}, %{state | connections: new_conns}}

              {:error, reason} ->
                GenServer.stop(pool, :normal, 5_000)
                new_conns = Map.delete(conns, name)

                {:reply, {:error, "Connection verification failed: #{reason}"},
                 %{state | connections: new_conns}}
            end

          {:error, reason} ->
            new_conns = Map.delete(conns, name)

            {:reply, {:error, "Failed to start connection pool: #{inspect(reason)}"},
             %{state | connections: new_conns}}
        end

      {:error, reason} ->
        new_conns = Map.delete(conns, name)
        {:reply, {:error, reason}, %{state | connections: new_conns}}
    end
  end

  def handle_call({:disconnect, name}, _from, %{connections: conns} = state) do
    case Map.get(conns, name) do
      %{pool: pool} ->
        GenServer.stop(pool, :normal, 5_000)
        DbMcp.Writes.purge_connection(name)
        DbMcp.Log.info("Disconnected '#{name}'")

        {:reply,
         {:ok, "Disconnected '#{name}'. Pending write queries for this connection purged."},
         %{state | connections: Map.delete(conns, name)}}

      nil ->
        {:reply, {:error, "No connection named '#{name}'."}, state}
    end
  end

  def handle_call(:disconnect_all, _from, %{connections: conns} = state) do
    Enum.each(conns, fn {_name, %{pool: pool}} ->
      GenServer.stop(pool, :normal, 5_000)
    end)

    DbMcp.Writes.purge_all()
    names = Map.keys(conns) |> Enum.join(", ")
    DbMcp.Log.info("Disconnected all: #{names}")

    {:reply, {:ok, "Disconnected all connections (#{names}). All pending writes purged."},
     %{state | connections: %{}}}
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
            "Pool: #{if pool_alive, do: "healthy", else: "unhealthy"}"

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

      %{pool: pool} ->
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

              {:error, %Postgrex.Error{postgres: %{message: msg}}} ->
                {:reply, {:error, "[#{name}] Query failed: #{msg}"}, state}

              {:error, reason} ->
                {:reply, {:error, "[#{name}] Query failed: #{inspect(reason)}"}, state}
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

      %{pool: pool} ->
        start_time = System.monotonic_time(:millisecond)

        case Postgrex.query(pool, sql, []) do
          {:ok, %Postgrex.Result{} = res} ->
            elapsed = System.monotonic_time(:millisecond) - start_time
            formatted = DbMcp.Format.format_write_result(res)
            {:reply, {:ok, "[#{name}] #{formatted}\n\nExecution time: #{elapsed}ms"}, state}

          {:error, %Postgrex.Error{postgres: %{message: msg}}} ->
            {:reply, {:error, "[#{name}] Execution failed: #{msg}"}, state}

          {:error, reason} ->
            {:reply, {:error, "[#{name}] Execution failed: #{inspect(reason)}"}, state}
        end
    end
  end

  defp verify_connection(pool) do
    case Postgrex.query(pool, "SELECT current_database(), current_user, version()", []) do
      {:ok, %Postgrex.Result{rows: [[_db, _user, version]]}} ->
        pg_version =
          case Regex.run(~r/PostgreSQL [\d.]+/, version) do
            [match] -> match
            _ -> version
          end

        {:ok, %{pg_version: pg_version}}

      {:error, reason} ->
        {:error, inspect(reason)}
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
            "Requires one biometric prompt, then the connection persists for the session. " <>
            "Supports multiple simultaneous connections via the 'name' parameter.",
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
                "A short name for this connection (e.g. 'prod', 'staging', 'analytics'). " <>
                  "Defaults to the database name from the credentials."
            }
          }
        }
      },
      %{
        "name" => "pg_disconnect",
        "description" =>
          "Close a PostgreSQL database connection and purge its pending write queries. " <>
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
          "Submit a write SQL query (INSERT, UPDATE, DELETE, DDL) for review. " <>
            "Returns a query ID that must be passed to 'pg_execute_write' to actually run it. " <>
            "Queries expire after 5 minutes.",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["sql"],
          "properties" => %{
            "sql" => %{
              "type" => "string",
              "description" => "The SQL write query to submit for review"
            },
            "connection" => @connection_prop,
            "description" => %{
              "type" => "string",
              "description" => "Optional human-readable description of what this query does"
            }
          }
        }
      },
      %{
        "name" => "pg_execute_write",
        "description" =>
          "Execute a previously submitted write query by its ID. " <>
            "The query must have been submitted via 'pg_submit_write' and not yet expired (5 min TTL). " <>
            "Each query ID can only be used once. The connection is determined automatically from the submission.",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["query_id"],
          "properties" => %{
            "query_id" => %{
              "type" => "string",
              "description" => "The query ID returned by 'pg_submit_write'"
            }
          }
        }
      }
    ]
  end

  def call("pg_connect", %{"vault_id" => vault_id, "item_name" => item_name} = params) do
    # If no explicit name, we'll use the database name after connecting.
    # To do that, we need creds first. But connect needs the name upfront.
    # Solution: fetch creds to get db name for default, then pass to connect.
    explicit_name = Map.get(params, "name")

    if explicit_name do
      do_connect(vault_id, item_name, explicit_name)
    else
      # Peek at creds to get database name for auto-naming
      case DbMcp.Credentials.fetch(vault_id, item_name) do
        {:ok, creds} ->
          auto_name = creds.database
          # Now connect — but creds are already fetched, so we'd double-fetch.
          # Instead, connect directly with the auto name (connect will re-fetch, but that's
          # fine since op caches the session after the first biometric prompt).
          do_connect(vault_id, item_name, auto_name)

        {:error, reason} ->
          tool_error(reason)
      end
    end
  end

  def call("pg_connect", _params) do
    tool_error("Missing required parameters: 'vault_id' and 'item_name'")
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
          {:ok, result} -> tool_result(result)
          {:error, reason} -> tool_error(reason)
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

        case DbMcp.Writes.submit(name, sql, description) do
          {:ok, id} ->
            desc_line = if description != "", do: "Description: #{description}\n", else: ""

            tool_result(
              "Write query submitted for review.\n\n" <>
                "Query ID: #{id}\n" <>
                "Connection: #{name}\n" <>
                desc_line <>
                "SQL:\n```sql\n#{sql}\n```\n\n" <>
                "To execute, call 'pg_execute_write' with query_id '#{id}'.\n" <>
                "This query will expire in 5 minutes."
            )

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

  def call("pg_execute_write", %{"query_id" => query_id}) do
    case DbMcp.Writes.fetch(query_id) do
      {:ok, connection_name, sql} ->
        case DbMcp.Connection.execute(connection_name, sql) do
          {:ok, result} -> tool_result(result)
          {:error, reason} -> tool_error(reason)
        end

      {:error, reason} ->
        tool_error(reason)
    end
  end

  def call("pg_execute_write", _params) do
    tool_error("Missing required parameter: 'query_id'")
  end

  def call(tool_name, _params) do
    tool_error("Unknown tool: #{tool_name}")
  end

  # Resolves which connection to use from params.
  # If "connection" is specified, use it. Otherwise, auto-resolve if exactly one exists.
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
    %{
      "content" => [%{"type" => "text", "text" => text}],
      "isError" => false
    }
  end

  defp tool_error(message) do
    %{
      "content" => [%{"type" => "text", "text" => "Error: #{message}"}],
      "isError" => true
    }
  end
end

defmodule DbMcp.Server do
  @moduledoc false

  @protocol_version "2025-11-25"
  @server_name "db-mcp"
  @server_version "1.0.0"

  def run do
    DbMcp.Log.info("Starting #{@server_name} v#{@server_version}")
    DbMcp.Log.info("MCP protocol version: #{@protocol_version}")

    {:ok, _} = DbMcp.Writes.start_link([])
    {:ok, _} = DbMcp.Connection.start_link([])

    DbMcp.Log.info("Server ready, waiting for input on stdin")
    loop()
  end

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
        DbMcp.Log.error("Unhandled exception: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")

        # Try to extract request id from the raw line for a proper JSON-RPC error response
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
      "capabilities" => %{
        "tools" => %{}
      },
      "serverInfo" => %{
        "name" => @server_name,
        "version" => @server_version
      }
    }

    {:ok, result}
  end

  defp handle_request("ping", _params) do
    {:ok, %{}}
  end

  defp handle_request("tools/list", _params) do
    {:ok, %{"tools" => DbMcp.Tools.definitions()}}
  end

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
    msg =
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => result
      }
      |> JSON.encode!()

    IO.puts(msg)
  end

  defp send_error(id, code, message) do
    msg =
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{
          "code" => code,
          "message" => message
        }
      }
      |> JSON.encode!()

    IO.puts(msg)
  end
end

# --- Entry Point ---
unless Code.ensure_loaded?(TestRunner) do
  Process.flag(:trap_exit, true)
  DbMcp.Server.run()
end
