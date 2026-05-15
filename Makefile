.PHONY: help install run server lint format check test test.unit test.integration test.database test.smoke clean distclean

ELIXIR ?= elixir
MIX ?= mix

## Show this help.
help:
	@awk 'BEGIN { FS = ":.*##|## "; printf "Usage:\n  make <target>\n\nTargets:\n" } /^[a-zA-Z0-9_.-]+:.*##/ { printf "  %-20s %s\n", $$1, $$2 } /^## / { help=$$0; sub(/^## /, "", help); getline; if ($$0 ~ /^[a-zA-Z0-9_.-]+:/) { target=$$1; sub(/:.*/, "", target); printf "  %-20s %s\n", target, help } }' $(MAKEFILE_LIST)

## Warm the Mix.install dep cache so first server boot is fast.
install:
	$(ELIXIR) -e 'Mix.install([{:postgrex, "~> 0.19"}, {:jason, "~> 1.4"}, {:sql_parser, "~> 0.2.5"}, {:bandit, "~> 1.0"}, {:websock_adapter, "~> 0.5"}]); IO.puts(:ok)'

## Run the MCP server locally over stdio.
run: server

## Run the MCP server locally over stdio.
server:
	$(ELIXIR) server.exs

## Run syntax and static checks (format-check + parse).
lint:
	$(MIX) format --check-formatted
	$(ELIXIR) -e 'Code.string_to_quoted!(File.read!("server.exs")); Code.string_to_quoted!(File.read!("test.exs")); IO.puts(:ok)'

## Format Elixir source files.
format:
	$(MIX) format

## Composite CI target: lint + unit tests.
check: lint test.unit

## Run all tests (unit + integration + database; requires Docker).
test:
	$(ELIXIR) test.exs --integration --database

## Run unit tests only (no external dependencies).
test.unit:
	$(ELIXIR) test.exs

## Run unit + integration tests (no Docker required).
test.integration:
	$(ELIXIR) test.exs --integration

## Run unit + database tests (requires Docker).
test.database:
	$(ELIXIR) test.exs --database

## Pre-push smoke gate: unit + integration (MCP handshake/tool-list + pty_bridge.py). No Docker.
test.smoke:
	$(ELIXIR) test.exs --integration

## Clear the Mix.install warm cache for this script's deps.
clean:
	rm -rf $${MIX_INSTALL_DIR:-$$HOME/.cache/mix/installs}

## Remove caches and any local build artifacts.
distclean: clean
	@:
