.PHONY: help infra dbt dlt grafana clickhouse superset api test deps-check setup dev
.DEFAULT_GOAL := help

# Prevent execution in production (user "databarn")
CURRENT_USER := $(shell whoami 2>/dev/null)
ifeq ($(CURRENT_USER),databarn)
    $(error This Makefile should not be run in production. Use infra/prod/Makefile instead.)
endif

ROOT_DIR := $(shell pwd)
DC := docker compose -f $(ROOT_DIR)/infra/dev/docker-compose.yml --env-file $(ROOT_DIR)/.env
UV := uv run --env-file $(ROOT_DIR)/.env

# Main help
help: ## Show this help message
	@echo "Beefy Databarn - Available commands:"
	@echo ""
	@echo "Usage: make <command> [subcommand]"
	@echo ""
	@$(MAKE) -s --no-print-directory dlt
	@$(MAKE) -s --no-print-directory infra
	@$(MAKE) -s --no-print-directory dbt
	@$(MAKE) -s --no-print-directory grafana
	@$(MAKE) -s --no-print-directory clickhouse
	@$(MAKE) -s --no-print-directory superset
	@$(MAKE) -s --no-print-directory api
	@$(MAKE) -s --no-print-directory test
	@echo "Dependencies:"
	@echo "  make deps-check          Check for outdated dependencies"
	@echo ""
	@echo "Workflows:"
	@echo "  make setup               Initial setup (copy .env, install deps)"
	@echo "  make start               Start infrastructure and initialize"
	@echo "  make dev                 Full development workflow"

# Infrastructure commands - using subcommands
infra:
	@SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
		start) \
			echo "Starting infrastructure services (rebuilding images if needed)..."; \
			$(DC) up -d --build; \
			echo "✓ Infrastructure services started"; \
			$(MAKE) -s _print-urls \
			;; \
		build) \
			echo "Rebuilding infrastructure images..."; \
			$(DC) build; \
			echo "✓ Infrastructure images rebuilt" \
			;; \
		stop) \
			echo "Stopping infrastructure services..."; \
			$(DC) down \
			;; \
		restart) \
			echo "Restarting infrastructure services..."; \
			$(DC) restart; \
			echo "✓ Infrastructure services restarted" \
			;; \
		logs) \
			$(DC) logs -f \
			;; \
		ps) \
			$(DC) ps \
			;; \
		help|"") \
			echo "Infrastructure:"; \
			echo "  make infra start         Start infrastructure services (rebuilds if needed)"; \
			echo "  make infra build         Rebuild infrastructure images"; \
			echo "  make infra stop          Stop infrastructure services"; \
			echo "  make infra restart       Restart infrastructure services"; \
			echo "  make infra logs          View infrastructure logs"; \
			echo "  make infra ps            Show service status"; \
			echo "" \
			;; \
		*) \
			echo "Usage: make infra [start|build|stop|restart|logs|ps|help]"; \
			exit 1 \
			;; \
	esac

# dbt commands - using subcommands
dbt:
	@cd dbt && unset VIRTUAL_ENV && \
	SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	MODEL="$(word 3,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
		run) \
			if [ -n "$$MODEL" ]; then \
				echo "Running dbt model: $$MODEL..."; \
				$(UV) dbt run --select $$MODEL --show-all-deprecations; \
			else \
				echo "Running dbt models..."; \
				$(UV) dbt run --show-all-deprecations; \
			fi \
			;; \
		test) \
			if [ -n "$$MODEL" ]; then \
				echo "Running dbt tests for model: $$MODEL..."; \
				$(UV) dbt test --select $$MODEL --write-json; \
			else \
				echo "Running dbt tests..."; \
				$(UV) dbt test --write-json; \
			fi \
			;; \
		compile) \
			echo "Compiling dbt models..."; \
			$(UV) dbt compile \
			;; \
		refresh) \
			MODEL="$(word 3,$(MAKECMDGOALS))" && \
			if [ -n "$$MODEL" ]; then \
				echo "Refreshing dbt model: $$MODEL..."; \
				$(UV) dbt run --select $$MODEL --full-refresh --show-all-deprecations; \
			else \
				echo "Refreshing all dbt models (full-refresh)..."; \
				$(UV) dbt run --full-refresh --show-all-deprecations; \
			fi; \
			echo "dbt refresh completed successfully"; \
			;; \
		sql) \
			echo "Compiling and showing SQL (no queries executed)..."; \
			if [ -n "$$MODEL" ]; then \
				$(UV) dbt compile --select $$MODEL > /dev/null 2>&1 && \
				COMPILED_FILE=$$(find target/compiled/beefy_databarn/models -name "$$MODEL.sql" -type f | head -1) && \
				if [ -n "$$COMPILED_FILE" ]; then \
					echo "=== Compiled SQL for $$MODEL ===" && \
					cat "$$COMPILED_FILE"; \
				else \
					echo "Error: Could not find compiled SQL for $$MODEL"; \
					exit 1; \
				fi; \
			else \
				$(UV) dbt compile > /dev/null 2>&1 && \
				echo "Compiled SQL files are in target/compiled/beefy_databarn/models/"; \
				find target/compiled/beefy_databarn/models -name "*.sql" -type f | head -10; \
			fi \
			;; \
		sql-explain) \
			if [ -z "$$MODEL" ]; then \
				echo "Usage: make dbt sql-explain <model>"; \
				exit 1; \
			fi; \
			echo "Explaining SQL for model: $$MODEL..."; \
			COMPILED_FILE=$$(find target/compiled/beefy_databarn/models -name "$$MODEL.sql" -type f | head -1) && \
			if [ -z "$$COMPILED_FILE" ]; then \
				echo "Error: Could not find compiled SQL for $$MODEL"; \
				exit 1; \
			fi; \
			echo "EXPLAIN query below in ClickHouse:"; \
			QUERY=$$(sed 's/"/\\"/g' "$$COMPILED_FILE") && \
			echo "========== RAW QUERY =========="; \
			cat "$$COMPILED_FILE"; \
			echo "========== EXPLAIN PIPELINE ==========\n"; \
			$(DC) exec clickhouse clickhouse-client --query="EXPLAIN PIPELINE  $${QUERY}"; \
			echo "========== EXPLAIN PLAN ==========\n"; \
			$(DC) exec clickhouse clickhouse-client --query="EXPLAIN PLAN indexes = 1, description = 1 $${QUERY}"; \
			echo "\n========== END =========="; \
			;; \
		docs) \
			echo "Generating dbt documentation (Docglow)..."; \
			$(UV) dbt docs generate && \
			DOCGLOW_NO_TELEMETRY=1 $(UV) docglow generate --project-dir . --output-dir ./target/docglow --static --enable-erd && \
			DOCGLOW_NO_TELEMETRY=1 $(UV) docglow serve --dir ./target/docglow \
			;; \
		help|"") \
			echo "dbt:"; \
			echo "  make dbt run             Run dbt models"; \
			echo "  make dbt run <model>     Run a specific dbt model"; \
			echo "  make dbt refresh         Full refresh all dbt models"; \
			echo "  make dbt refresh <model> Full refresh a specific dbt model"; \
			echo "  make dbt test            Run dbt tests"; \
			echo "  make dbt compile         Compile dbt models"; \
			echo "  make dbt sql [<model>]   Show compiled SQL (optionally for specific model)"; \
			echo "  make dbt docs            Generate and serve Docglow documentation"; \
			echo "" \
			;; \
		*) \
			echo "Usage: make dbt [run [model]|refresh [model]|test [model]|compile|sql [model_name]|docs|help]"; \
			exit 1 \
			;; \
	esac

# dlt commands - using subcommands (infra/dlt/set_dlt_env.sh maps .env to DLT env vars)
dlt:
	@cd dlt && unset VIRTUAL_ENV && . ../infra/dlt/set_dlt_env.sh && \
	SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	SOURCE="$(word 3,$(MAKECMDGOALS))" && \
	RESOURCE="$(word 4,$(MAKECMDGOALS))" && \
	SINCE="$(word 5,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
		run) \
			if [ -n "$$RESOURCE" ] && [ -n "$$SOURCE" ]; then \
				echo "Running dlt source: $$SOURCE, resource: $$RESOURCE..."; \
				$(UV) ./$${SOURCE}_pipeline.py $$RESOURCE; \
			elif [ -n "$$SOURCE" ]; then \
				echo "Running dlt source: $$SOURCE..."; \
				$(UV) ./$${SOURCE}_pipeline.py; \
			elif [ -z "$$SOURCE" ]; then \
				echo "Running all dlt pipelines..."; \
				$(UV) ./all_pipeline.py; \
			else \
				echo "Usage: make dlt run <source> [resource]"; \
				exit 1; \
			fi \
			;; \
		optimize) \
			echo "Optimizing ReplacingMergeTree tables..."; \
			$(UV) ./optimize_replacing_tables.py; \
			;; \
		cleanup-pipeline-state) \
			echo "Cleaning up deprecated dlt pipeline state..."; \
			$(UV) ./cleanup_pipeline_state.py; \
			;; \
		loop) \
			if [ -n "$$RESOURCE" ] && [ -n "$$SOURCE" ]; then \
				echo "Looping dlt pipeline: $$SOURCE, resource: $$RESOURCE..."; \
				$(UV) ./$${SOURCE}_pipeline.py $$RESOURCE --loop; \
			else \
				echo "Usage: make dlt loop <source> <resource>"; \
				exit 1; \
			fi \
			;; \
		reimport) \
			if [ -n "$$RESOURCE" ] && [ -n "$$SOURCE" ]; then \
				if [ -n "$$SINCE" ]; then \
					echo "Reimporting dlt source: $$SOURCE, resource: $$RESOURCE since $$SINCE..."; \
					$(UV) ./$${SOURCE}_pipeline.py $$RESOURCE --reimport $$SINCE --loop; \
				else \
					echo "Reimporting dlt source: $$SOURCE, resource: $$RESOURCE (full history)..."; \
					$(UV) ./$${SOURCE}_pipeline.py $$RESOURCE --reimport --loop; \
				fi; \
			else \
				echo "Usage: make dlt reimport <source> <resource> [<since>]"; \
				echo "  since: YYYY-MM-DD, 90d, 3m, or omit for full history"; \
				exit 1; \
			fi \
			;; \
		info|show|failed-jobs|drop-pending-packages|sync|trace|schema|load-package|mcp) \
			if [ -n "$$SOURCE" ]; then \
				echo "Running: $(UV) dlt pipeline $$SOURCE $$SUBCMD"; \
				$(UV) dlt pipeline -v $$SOURCE $$SUBCMD; \
			else \
				echo "Usage: make dlt <action> <pipeline>"; \
				echo "  action: info, show, failed-jobs, drop-pending-packages, sync, trace, schema, load-package, mcp"; \
				echo "  pipeline: e.g. beefy_db, beefy_api, github_files, beefy_cctp_api"; \
				exit 1; \
			fi \
			;; \
		drop) \
			if [ -n "$$SOURCE" ]; then \
				echo "Running: $(UV) dlt pipeline $$SOURCE drop $$RESOURCE"; \
				$(UV) dlt pipeline -v $$SOURCE drop $$RESOURCE; \
			else \
				echo "Usage: make dlt drop <pipeline> <resource>"; \
				echo "  pipeline: e.g. beefy_db, beefy_api, github_files, beefy_cctp_api"; \
				echo "  resource: e.g. zap_events, harvest_events, vaults, tokens"; \
				exit 1; \
			fi \
			;; \
		help|"") \
			echo "dlt:"; \
			echo "  make dlt run                    Run all dlt pipelines"; \
			echo "  make dlt run <source> [resource]         Run a specific pipeline or resource"; \
			echo "                                  Examples: beefy_db vaults, beefy_api tokens, beefy_history"; \
			echo "  make dlt optimize               OPTIMIZE FINAL on ReplacingMergeTree tables"; \
			echo "  make dlt cleanup-pipeline-state Delete superseded _dlt_pipeline_state rows"; \
			echo "  make dlt loop <source> <resource>    Loop until an incremental resource is caught up"; \
			echo "  make dlt reimport <source> <resource> [<since>]"; \
			echo "                                  Rewind cursor and re-append (loops, never truncates)."; \
			echo "                                  since: YYYY-MM-DD, 90d, 3m; omit for full history"; \
			echo "  make dlt <action> <pipeline>    Run dlt pipeline command (uvx dlt pipeline ...)"; \
			echo "                                  action: info, show, failed-jobs, drop-pending-packages, sync, trace, schema, drop, load-package, mcp"; \
			echo "" \
			;; \
		*) \
			echo "Usage: make dlt [run <source> [resource]|optimize|cleanup-pipeline-state|loop <source> <resource>|reimport <source> <resource> [<since>]|<action> <pipeline>|help]"; \
			echo "  source/pipeline: e.g. beefy_db, beefy_api, github_files, beefy_cctp_api, beefy_history"; \
			echo "  resource: e.g. feebatch_harvests, vaults, tokens"; \
			echo "  action: info, show, failed-jobs, drop-pending-packages, sync, trace, schema, drop, load-package, mcp"; \
			exit 1 \
			;; \
	esac


# Grafana commands - using subcommands
gf: grafana # alias for grafana
grafana:
	@SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
		start|up) \
			echo "Starting Grafana..."; \
			$(DC) up -d grafana; \
			echo "✓ Grafana started" \
			;; \
		stop) \
			echo "Stopping Grafana..."; \
			$(DC) stop grafana; \
			echo "✓ Grafana stopped" \
			;; \
		restart) \
			echo "Restarting Grafana (reload configs)..."; \
			$(DC) restart grafana; \
			echo "✓ Grafana restarted" \
			;; \
		logs) \
			$(DC) logs -f grafana \
			;; \
		ps) \
			$(DC) ps grafana \
			;; \
		help|"") \
			echo "Grafana:"; \
			echo "  make [grafana|gf] start        Start Grafana"; \
			echo "  make [grafana|gf] stop         Stop Grafana"; \
			echo "  make [grafana|gf] restart      Restart Grafana (reload configs)"; \
			echo "  make [grafana|gf] logs         View Grafana logs"; \
			echo "  make [grafana|gf] ps           Show Grafana status"; \
			echo "" \
			;; \
		*) \
			echo "Usage: make [grafana|gf] [start|stop|restart|logs|ps|help]"; \
			exit 1 \
			;; \
	esac

# ClickHouse commands - using subcommands
ch: clickhouse # alias for clickhouse
clickhouse:
	@SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	USER="$(word 3,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
		stop) \
			echo "Stopping ClickHouse..."; \
			$(DC) stop clickhouse; \
			echo "✓ ClickHouse stopped" \
			;; \
		restart) \
			echo "Restarting ClickHouse..."; \
			$(DC) restart clickhouse; \
			echo "✓ ClickHouse restarted" \
			;; \
		client|cli) \
			if [ -n "$$USER" ]; then \
				echo "Opening ClickHouse client shell as user: $$USER..."; \
				$(DC) exec clickhouse clickhouse-client --user $$USER; \
			else \
				echo "Opening ClickHouse client shell (default user)..."; \
				$(DC) exec clickhouse clickhouse-client; \
			fi \
			;; \
		backup) \
			MODE="$(word 3,$(MAKECMDGOALS))"; \
			if [ "$$MODE" = "full" ] || [ "$$MODE" = "incremental" ]; then \
				echo "Running one-shot $$MODE backup..."; \
				$(DC) exec clickhouse-backup /bin/bash /opt/backup-loop.sh once $$MODE; \
			else \
				echo "Running one-shot backup (auto full/incremental)..."; \
				$(DC) exec clickhouse-backup /bin/bash /opt/backup-loop.sh once auto; \
			fi \
			;; \
		backup-status) \
			$(DC) exec clickhouse-backup /bin/bash /opt/backup-loop.sh status \
			;; \
		backup-restart) \
			echo "Recreating clickhouse-backup..."; \
			$(DC) up -d --force-recreate clickhouse-backup; \
			echo "✓ clickhouse-backup recreated" \
			;; \
		version) \
			$(DC) exec clickhouse clickhouse-client --query "SELECT version()" \
			;; \
		restore) \
			if [ -z "$(BACKUP)" ]; then \
				echo "Usage: make clickhouse restore BACKUP=inc-YYYY-MM-DD-HH (or full-YYYY-MM-DD)"; \
				exit 1; \
			fi; \
			echo "Restoring from S3 prefix $(BACKUP)..."; \
			$(DC) exec clickhouse-backup /bin/bash /opt/backup-loop.sh restore "$(BACKUP)" \
			;; \
		help|"") \
			echo "ClickHouse:"; \
			echo "  make [clickhouse|ch] stop              Stop ClickHouse"; \
			echo "  make [clickhouse|ch] restart          Re-restart ClickHouse (reload configs)"; \
			echo "  make [clickhouse|ch] client [<user>]  Open ClickHouse client shell (default user)"; \
			echo "  make [clickhouse|ch] backup [full|incremental]  One-shot backup to S3"; \
			echo "  make [clickhouse|ch] backup-status    Show recent backups and S3 prefixes"; \
			echo "  make [clickhouse|ch] backup-restart   Recreate backup sidecar (reload loop script/env)"; \
			echo "  make [clickhouse|ch] version          Show server version"; \
			echo "  make [clickhouse|ch] restore BACKUP=<prefix>  RESTORE ALL from that prefix"; \
			echo "" \
			;; \
		*) \
			echo "Usage: make [clickhouse|ch] [stop|restart|client [user]|backup [full|incremental]|backup-status|backup-restart|version|restore|help]"; \
			exit 1 \
			;; \
	esac

# Superset commands - using subcommands
superset:
	@SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
		stop) \
			echo "Stopping Superset..."; \
			$(DC) stop superset; \
			echo "✓ Superset stopped" \
			;; \
		restart) \
			echo "Restarting Superset (rebuild image)..."; \
			$(DC) up -d --force-recreate --build --no-deps superset; \
			echo "✓ Superset restarted" \
			;; \
		build) \
			echo "Building Superset image..."; \
			$(DC) build superset; \
			echo "✓ Superset image built" \
			;; \
		logs) \
			$(DC) logs -f superset \
			;; \
		sync|sync-datasources) \
			echo "Syncing Superset datasources (refresh dataset metadata)..."; \
			$(DC) exec superset python3 /usr/local/bin/provision/sync-datasources.py || true; \
			echo "✓ Datasources sync completed" \
			;; \
		help|"") \
			echo "Superset:"; \
			echo "  make superset stop             Stop Superset"; \
			echo "  make superset restart          Restart Superset (reload configs)"; \
			echo "  make superset build            Build Superset image"; \
			echo "  make superset logs            View Superset logs"; \
			echo "  make superset sync-datasources Refresh dataset metadata from databases"; \
			echo "" \
			;; \
		*) \
			echo "Usage: make superset [stop|restart|build|logs|sync-datasources|help]"; \
			exit 1 \
			;; \
	esac

# API commands - using subcommands
api:
	@cd api && unset VIRTUAL_ENV && \
	SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
		dev) \
			echo "Starting API service in dev mode (with auto-reload)..."; \
			$(UV) uvicorn main:app --host 0.0.0.0 --port 8080 --reload \
			;; \
		help|"") \
			echo "API:"; \
			echo "  make api dev              Start API service in dev mode (with auto-reload)"; \
			echo "" \
			;; \
		*) \
			echo "Usage: make api [dev|help]"; \
			exit 1 \
			;; \
	esac

# Unit tests - using subcommands
test:
	@SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
		unit) \
			echo "Running infra unit tests..."; \
			uv run --with pytest pytest infra/tests; \
			echo "Running dlt unit tests..."; \
			cd dlt && unset VIRTUAL_ENV && uv run --extra dev pytest \
			;; \
		help|"") \
			echo "Tests:"; \
			echo "  make test unit           Run Python unit tests (infra + dlt)"; \
			echo "" \
			;; \
		*) \
			echo "Usage: make test [unit|help]"; \
			exit 1 \
			;; \
	esac

# Dependencies
deps-check: ## Check for outdated dependencies
	@echo "Checking for outdated dependencies..."
	@echo ""
	@echo "Currently installed packages:"
	@uv pip list
	@echo ""
	@echo "Checking for available updates..."
	@uv pip list --outdated 2>/dev/null || (echo "No outdated packages found (or command not available)" && echo "")
	@echo ""
	@echo "To update dependencies:"
	@echo "  1. Edit pyproject.toml with desired version constraints"
	@echo "  2. Run: uv lock --upgrade"
	@echo "  3. Run: uv sync"

# Setup commands
setup: ## Initial setup (copy .env, install deps)
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "✓ Created .env file - please edit it with your credentials"; \
	else \
		echo "✓ .env file already exists"; \
	fi
	@echo "Installing dependencies for each application..."
	@cd dlt && uv sync || echo "Warning: dlt dependencies not installed"
	@cd dbt && uv sync || echo "Warning: dbt dependencies not installed"
	@cd api && uv sync || echo "Warning: api dependencies not installed"
	@echo "✓ Dependencies installed"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Edit .env with your credentials"
	@echo "  2. make infra start"
	@echo "  3. make dbt run"

dev: ## Full development workflow (setup, start, run dbt)
	@$(MAKE) -s setup
	@$(MAKE) -s infra start
	@echo "Waiting for services to be healthy..."
	@sleep 10
	@$(MAKE) -s dbt run
	@echo ""
	@echo "✓ Development environment ready!"
	@$(MAKE) -s _print-urls

# Shared utility targets
_print-urls:
	@echo ""
	@echo "Access services:"
	echo "  - API: http://localhost:8080/docs" && \
	echo "  - Superset: http://localhost:8088" && \
	echo "  - Traefik Dashboard: http://localhost:8080" && \
	echo "  - ClickHouse: http://localhost:$${CLICKHOUSE_HOST_HTTP_PORT:-18123} ($${CLICKHOUSE_USER:-default}/$${CLICKHOUSE_PASSWORD:-<set in .env>})" && \
	echo "  - Grafana: http://localhost:3000 ($${GRAFANA_ADMIN_USER:-admin}/$${GRAFANA_ADMIN_PASSWORD:-admin})" && \
	echo "  - Prometheus: http://localhost:9090 (no auth)" && \
	echo "  - RustFS: http://localhost:9001 ($${RUSTFS_ACCESS_KEY:-admin}/$${RUSTFS_SECRET_KEY:-admin})"

# Catch-all target to prevent "No rule to make target" errors
# This allows arguments to be passed to targets without make complaining
%:
	@:

