.PHONY: test test.unit test.integration test.database

## Run all tests (unit + integration + database; requires Docker)
test:
	elixir test.exs --integration --database

## Run unit tests only (no external dependencies)
test.unit:
	elixir test.exs

## Run unit + integration tests (no Docker required)
test.integration:
	elixir test.exs --integration

## Run unit + database tests (requires Docker)
test.database:
	elixir test.exs --database
