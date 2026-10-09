# Makefile for Docker Compose operations
# This Makefile provides commands for building images and managing the Docker Compose stack
# Uses docker rollout plugin for no-downtime deployments

.PHONY: help build ps logs deploy ensure-dirs restart dbt dlt clickhouse superset grafana gf run test client github_files tvls beefy_db beefy_api beefy_cctp_api beefy_history loop docker reimport
.DEFAULT_GOAL := help

# Paths and common commands
ROOT_DIR := $(abspath ../..)
DC := docker compose -f $(ROOT_DIR)/infra/prod/docker-compose.yml --env-file $(ROOT_DIR)/.env
UV := uv run --env-file $(ROOT_DIR)/.env

# Directories that need to exist for bind mounts (override via .env if present)
STORAGE_DIR ?= /mnt/data
DATA_DIRS := $(STORAGE_DIR)/clickhouse \
             $(STORAGE_DIR)/prometheus \
             $(STORAGE_DIR)/grafana \
             $(STORAGE_DIR)/rustfs \
             $(STORAGE_DIR)/postgres \
             $(STORAGE_DIR)/superset \
             $(STORAGE_DIR)/redis \
             $(STORAGE_DIR)/traefik_certs \
             $(STORAGE_DIR)/dbt \
             $(STORAGE_DIR)/dbt-docs \
             $(STORAGE_DIR)/dlt \
             $(STORAGE_DIR)/beefy-history

# Default target
.DEFAULT_GOAL := help

# Show help message
help:
	@echo "Available commands:"
	@echo ""
	@$(MAKE) -s --no-print-directory build
	@$(MAKE) -s --no-print-directory dbt
	@$(MAKE) -s --no-print-directory dlt
	@$(MAKE) -s --no-print-directory clickhouse
	@$(MAKE) -s --no-print-directory grafana
	@$(MAKE) -s --no-print-directory superset
	@$(MAKE) -s --no-print-directory infra
	@$(MAKE) -s --no-print-directory docker


infra: ensure-dirs
	@SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
		build) \
			SERVICE="$(word 3,$(MAKECMDGOALS))" && \
			if [ -n "$$SERVICE" ]; then \
				echo "Rebuilding infrastructure image: $$SERVICE..."; \
				$(DC) build $$SERVICE; \
				echo "✓ Infrastructure image $$SERVICE rebuilt"; \
			else \
				echo "Rebuilding infrastructure images..."; \
				$(DC) build; \
				echo "✓ Infrastructure images rebuilt"; \
			fi; \
			;; \
		start|up) \
			echo "Starting infrastructure services (rebuilding images if needed)..."; \
			$(DC) up -d; \
			echo "✓ Infrastructure services started"; \
			$(MAKE) -s _print-urls \
			;; \
		stop) \
			echo "Stopping infrastructure services..."; \
			$(DC) down; \
			echo "✓ Infrastructure services stopped"; \
			;; \
		restart) \
			echo "Restarting infrastructure services..."; \
			$(DC) restart; \
			echo "✓ Infrastructure services restarted"; \
			;; \
		logs) \
			$(DC) logs -f; \
			;; \
		ps) \
			$(DC) ps; \
			;; \
		help|"") \
			echo "infra:"; \
			echo "  make infra build [<svc>] Build all images (or only <svc>, e.g. dlt)"; \
			echo "  make infra start         Start infrastructure services (rebuilds if needed)"; \
			echo "  make infra stop          Stop infrastructure services"; \
			echo "  make infra restart       Restart infrastructure services"; \
			echo "  make infra logs          View infrastructure logs"; \
			echo "  make infra ps            Show service status"; \
			echo "" \
			;; \
		*) \
			echo "Usage: make infra [build [<svc>]|start|stop|restart|logs|ps|help]"; \
			exit 1; \
		;; \
	esac

# Grafana commands - using subcommands (published image; restart recreates to pick up tag/config)
gf: grafana
grafana:
	@SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
		start|up) \
			echo "Starting Grafana..."; \
			$(DC) up -d grafana; \
			echo "✓ Grafana started"; \
		;; \
		restart) \
			echo "Recreating Grafana..."; \
			$(DC) up -d --force-recreate --no-deps grafana; \
			echo "✓ Grafana recreated"; \
		;; \
		logs) \
			echo "Showing Grafana logs..."; \
			$(DC) logs -f grafana; \
		;; \
		ps) \
			echo "Showing Grafana service status..."; \
			$(DC) ps grafana; \
		;; \
		help|"") \
			echo "Grafana:"; \
			echo "  make [grafana|gf] start     Start Grafana"; \
			echo "  make [grafana|gf] restart   Recreate Grafana (new image tag / grafana.ini)"; \
			echo "  make [grafana|gf] logs      View Grafana logs"; \
			echo "  make [grafana|gf] ps        Show Grafana status"; \
			echo "" \
			;; \
		*) \
			echo "Usage: make [grafana|gf] [start|restart|logs|ps|help]"; \
			exit 1 \
			;; \
	esac

# Superset commands - using subcommands
superset:
	@SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
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
			echo "  make superset restart          Restart Superset (reload configs)"; \
			echo "  make superset build            Build Superset image"; \
			echo "  make superset logs            View Superset logs"; \
			echo "  make superset sync-datasources Refresh dataset metadata from databases"; \
			echo "" \
			;; \
		*) \
			echo "Usage: make superset [restart|build|logs|sync-datasources|help]"; \
			exit 1 \
			;; \
	esac

# Run dbt: make dbt run or make dbt test
# Usage: make dbt run or make dbt test
dbt:
	@SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
		logs) \
			echo "$$SUBCMD dbt..."; \
			$(DC) logs -f dbt; \
		;; \
		restart) \
			echo "Restarting dbt..."; \
			$(DC) up -d --force-recreate --build dbt; \
		;; \
		refresh) \
			MODEL="$(word 3,$(MAKECMDGOALS))" && \
			if [ -n "$$MODEL" ]; then \
				echo "Refreshing dbt model: $$MODEL..."; \
				$(DC) exec dbt /app/run_dbt_with_lock.sh run --full-refresh --select $$MODEL; \
			else \
				echo "Refreshing all dbt models (full-refresh)..."; \
				$(DC) exec dbt /app/run_dbt_with_lock.sh run --full-refresh; \
			fi && \
			echo "dbt refresh completed successfully"; \
		;; \
		run) \
			echo "Running dbt..."; \
			MODEL="$(word 3,$(MAKECMDGOALS))" && \
			if [ -n "$$MODEL" ]; then \
				echo "Running dbt model: $$MODEL..."; \
				$(DC) exec dbt /app/run_dbt_with_lock.sh run --select $$MODEL; \
			else \
				echo "Running all dbt models..."; \
				$(DC) exec dbt /app/run_dbt_with_lock.sh run; \
			fi && \
			echo "dbt run completed successfully"; \
		;; \
		test) \
			echo "Testing dbt..."; \
			MODEL="$(word 3,$(MAKECMDGOALS))" && \
			if [ -n "$$MODEL" ]; then \
				echo "Testing dbt model: $$MODEL..."; \
				$(DC) exec dbt /app/run_dbt_with_lock.sh test --select $$MODEL; \
			else \
				echo "Testing all dbt models..."; \
				$(DC) exec dbt /app/run_dbt_with_lock.sh test; \
			fi && \
			echo "dbt test completed successfully"; \
		;; \
		docs) \
			echo "Generating and publishing dbt docs..."; \
			$(DC) exec dbt /app/publish_docs.sh; \
			echo "dbt docs published"; \
		;; \
		help|"") \
			echo "dbt:"; \
			echo "  make dbt run [<model>]     Run dbt models"; \
			echo "  make dbt refresh [<model>] Full refresh all dbt models (or a specific model)"; \
			echo "  make dbt test [<model>]    Run dbt tests"; \
			echo "  make dbt docs              Generate and publish Docglow docs"; \
			echo "" \
			;; \
		*) \
			echo "Usage: make dbt [run [<model>]|refresh [<model>]|test [<model>]|docs|help]"; \
			exit 1; \
		;; \
	esac

# Run dlt: make dlt run
# Usage: make dlt run
dlt:
	@SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
		logs) \
			echo "Showing dlt logs..."; \
			$(DC) logs -f dlt; \
		;; \
		restart) \
			echo "Restarting dlt..."; \
			$(DC) up -d --force-recreate --build dlt; \
		;; \
		ps) \
			echo "Showing dlt service status..."; \
			$(DC) ps dlt; \
		;; \
		run) \
			echo "Running dlt..."; \
			SOURCE="$(word 3,$(MAKECMDGOALS))" && \
			RESOURCE="$(word 4,$(MAKECMDGOALS))" && \
			if [ -n "$$RESOURCE" ] && [ -n "$$SOURCE" ]; then \
				echo "Running dlt source: $$SOURCE, resource: $$RESOURCE..."; \
				$(DC) exec dlt /app/infra/dlt/entrypoint.sh uv run /app/dlt/$${SOURCE}_pipeline.py $$RESOURCE; \
			elif [ -n "$$SOURCE" ]; then \
				echo "Running dlt source: $$SOURCE..."; \
				$(DC) exec dlt /app/infra/dlt/entrypoint.sh uv run /app/dlt/$${SOURCE}_pipeline.py; \
			else \
				echo "Usage: make dlt run <source>|all [resource]"; \
				exit 1; \
			fi; \
		;; \
		optimize) \
			echo "Optimizing ReplacingMergeTree tables..."; \
			$(DC) exec dlt /app/infra/dlt/entrypoint.sh uv run /app/dlt/optimize_replacing_tables.py; \
		;; \
		cleanup-pipeline-state) \
			echo "Cleaning up deprecated dlt pipeline state..."; \
			$(DC) exec dlt /app/infra/dlt/entrypoint.sh uv run /app/dlt/cleanup_pipeline_state.py; \
		;; \
		loop) \
			echo "Looping dlt..."; \
			SOURCE="$(word 3,$(MAKECMDGOALS))" && \
			RESOURCE="$(word 4,$(MAKECMDGOALS))" && \
			if [ -n "$$RESOURCE" ] && [ -n "$$SOURCE" ]; then \
				echo "Looping dlt source: $$SOURCE, resource: $$RESOURCE..."; \
				$(DC) exec dlt /app/infra/dlt/entrypoint.sh uv run /app/dlt/$${SOURCE}_pipeline.py $$RESOURCE --loop; \
			else \
				echo "Usage: make dlt loop <source> <resource>"; \
				exit 1; \
			fi; \
			echo "dlt loop completed successfully"; \
		;; \
		reimport) \
			SOURCE="$(word 3,$(MAKECMDGOALS))" && \
			RESOURCE="$(word 4,$(MAKECMDGOALS))" && \
			SINCE="$(word 5,$(MAKECMDGOALS))" && \
			if [ -n "$$RESOURCE" ] && [ -n "$$SOURCE" ]; then \
				if [ -n "$$SINCE" ]; then \
					echo "Reimporting dlt source: $$SOURCE, resource: $$RESOURCE since $$SINCE..."; \
					$(DC) exec dlt /app/infra/dlt/entrypoint.sh uv run /app/dlt/$${SOURCE}_pipeline.py $$RESOURCE --reimport $$SINCE --loop; \
				else \
					echo "Reimporting dlt source: $$SOURCE, resource: $$RESOURCE (full history)..."; \
					$(DC) exec dlt /app/infra/dlt/entrypoint.sh uv run /app/dlt/$${SOURCE}_pipeline.py $$RESOURCE --reimport --loop; \
				fi; \
			else \
				echo "Usage: make dlt reimport <source> <resource> [<since>]"; \
				echo "  since: YYYY-MM-DD, 90d, 3m, or omit for full history"; \
				exit 1; \
			fi; \
		;; \
		info|show|failed-jobs|drop-pending-packages|trace|schema|load-package|mcp) \
			SOURCE="$(word 3,$(MAKECMDGOALS))" && \
			RESOURCE="$(word 4,$(MAKECMDGOALS))" && \
			if [ -n "$$SOURCE" ]; then \
				echo "Running: dlt pipeline $$SOURCE $$SUBCMD..."; \
				$(DC) exec dlt /app/infra/dlt/entrypoint.sh uv run dlt pipeline -v $$SOURCE $$SUBCMD $$RESOURCE; \
			else \
				echo "Usage: make dlt <action> <pipeline> <resource>"; \
				echo "  action: info, show, failed-jobs, drop-pending-packages, trace, schema, load-package, mcp"; \
				echo "  pipeline: e.g. beefy_db, beefy_api, github_files, beefy_cctp_api"; \
				echo "  resource: e.g. zap_events, harvest_events, vaults, tokens"; \
				exit 1; \
			fi; \
		;; \
		drop-state) \
			SOURCE="$(word 3,$(MAKECMDGOALS))" && \
			RESOURCE="$(word 4,$(MAKECMDGOALS))" && \
			if [ -n "$$SOURCE" ] && [ -n "$$RESOURCE" ]; then \
				echo "Running: dlt pipeline $$SOURCE drop --state-only $$RESOURCE..."; \
				$(DC) exec dlt /app/infra/dlt/entrypoint.sh uv run dlt pipeline -v $$SOURCE drop --state-only $$RESOURCE; \
			else \
				echo "Usage: make dlt drop-state <pipeline> <resource>"; \
				echo "  pipeline: e.g. beefy_db, beefy_api, github_files, beefy_cctp_api"; \
				echo "  resource: e.g. zap_events, harvest_events, vaults, tokens"; \
				exit 1; \
			fi; \
		;; \
		drop) \
			SOURCE="$(word 3,$(MAKECMDGOALS))" && \
			RESOURCE="$(word 4,$(MAKECMDGOALS))" && \
			if [ -n "$$SOURCE" ] && [ -n "$$RESOURCE" ]; then \
				echo "Running: dlt pipeline $$SOURCE $$SUBCMD $$RESOURCE..."; \
				$(DC) exec dlt /app/infra/dlt/entrypoint.sh uv run dlt pipeline -v $$SOURCE $$SUBCMD $$RESOURCE; \
			else \
				echo "Usage: make dlt <action> <pipeline> <resource>"; \
				echo "  pipeline: e.g. beefy_db, beefy_api, github_files, beefy_cctp_api"; \
				echo "  resource: e.g. zap_events, harvest_events, vaults, tokens"; \
				echo "  action: drop"; \
				exit 1; \
			fi; \
		;; \
		help|"") \
			echo "dlt:"; \
			echo "  make dlt run [<pipeline>|all] [resource]   Run dlt pipeline"; \
			echo "  make dlt optimize                          OPTIMIZE FINAL on ReplacingMergeTree tables"; \
			echo "  make dlt cleanup-pipeline-state            Delete superseded _dlt_pipeline_state rows"; \
			echo "  make dlt loop <source> <resource>          Loop dlt pipeline for a resource"; \
			echo "  make dlt reimport <source> <resource> [<since>]"; \
			echo "      Rewind cursor and re-append (loops, never truncates)."; \
			echo "      since: YYYY-MM-DD, 90d, 3m; omit for full history"; \
			echo "  make dlt <action> <pipeline> <resource>               Run dlt pipeline command"; \
			echo "      action: info, show, failed-jobs, drop-pending-packages, trace, schema, load-package, mcp, drop, drop-state"; \
			echo "" \
			;; \
		*) \
			echo "Usage: make dlt [run [<pipeline>|all] [resource]|optimize|cleanup-pipeline-state|loop <source> <resource>|reimport <source> <resource> [<since>]|<action> <pipeline> <resource>|help]"; \
			echo "  pipeline/source: e.g. beefy_db, beefy_api, github_files, beefy_cctp_api, beefy_history"; \
			echo "  resource: e.g. zap_events, harvest_events, vaults, tokens"; \
			echo "  action: info, show, failed-jobs, drop-pending-packages, trace, schema, load-package, mcp, drop, drop-state"; \
			exit 1; \
		;; \
	esac

# ClickHouse client: make clickhouse client
# Usage: make clickhouse client
ch: clickhouse # alias for clickhouse
clickhouse:
	@SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
		logs) \
			echo "Showing ClickHouse logs..."; \
			$(DC) logs -f clickhouse; \
		;; \
		restart) \
			echo "Restarting ClickHouse..."; \
			$(DC) up -d --force-recreate --build clickhouse; \
		;; \
		ps) \
			echo "Showing ClickHouse service status..."; \
			$(DC) ps clickhouse; \
		;; \
		client|cli) \
			echo "Opening ClickHouse client..."; \
			$(DC) exec clickhouse clickhouse-client; \
		;; \
		backup) \
			MODE="$(word 3,$(MAKECMDGOALS))"; \
			if [ "$$MODE" = "full" ] || [ "$$MODE" = "incremental" ]; then \
				echo "Running one-shot $$MODE backup..."; \
				$(DC) exec clickhouse-backup /bin/bash /opt/backup-loop.sh once $$MODE; \
			else \
				echo "Running one-shot backup (auto full/incremental)..."; \
				$(DC) exec clickhouse-backup /bin/bash /opt/backup-loop.sh once auto; \
			fi; \
		;; \
		backup-status) \
			$(DC) exec clickhouse-backup /bin/bash /opt/backup-loop.sh status; \
		;; \
		backup-restart) \
			echo "Recreating clickhouse-backup..."; \
			$(DC) up -d --force-recreate clickhouse-backup; \
			echo "✓ clickhouse-backup recreated"; \
		;; \
		version) \
			$(DC) exec clickhouse clickhouse-client --query "SELECT version()"; \
		;; \
		restore) \
			if [ -z "$(BACKUP)" ]; then \
				echo "Usage: make clickhouse restore BACKUP=inc-YYYY-MM-DD-HH (or full-YYYY-MM-DD)"; \
				exit 1; \
			fi; \
			echo "Restoring from S3 prefix $(BACKUP)..."; \
			$(DC) exec clickhouse-backup /bin/bash /opt/backup-loop.sh restore "$(BACKUP)"; \
		;; \
		help|"") \
			echo "clickhouse:"; \
			echo "  make clickhouse client   Open ClickHouse client"; \
			echo "  make clickhouse version  Show server version"; \
			echo "  make clickhouse backup [full|incremental]  One-shot backup to S3"; \
			echo "  make clickhouse backup-status    Show recent backups"; \
			echo "  make clickhouse backup-restart   Recreate backup sidecar (reload loop script/env)"; \
			echo "  make clickhouse restore BACKUP=<prefix>  RESTORE ALL from that prefix"; \
			echo "" \
			;; \
		*) \
			echo "Usage: make clickhouse [client|version|backup [full|incremental]|backup-status|backup-restart|restore|help]"; \
			exit 1; \
		;; \
	esac

postgres:
	@SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
		client|cli) \
			echo "Opening Postgres client..."; \
			$(DC) exec postgres psql"; \
		;; \
		logs) \
			echo "Showing Postgres logs..."; \
			$(DC) logs -f postgres; \
		;; \
		restart) \
			echo "Restarting Postgres..."; \
			$(DC) up -d --force-recreate --build postgres; \
		;; \
		ps) \
			echo "Showing Postgres service status..."; \
			$(DC) ps postgres; \
		;; \
		help|"") \
		;; \
		*) \
			echo "Usage: make postgres [logs|restart|ps|help]"; \
			exit 1; \
		;; \
	esac

# Docker: prune (clean up old Docker images/containers; runs only if all services are up)
docker:
	@SUBCMD="$(word 2,$(MAKECMDGOALS))" && \
	case "$$SUBCMD" in \
		prune) \
			EXPECTED=$$($(DC) config --services | wc -l); \
			echo "Checking all $$EXPECTED services are running..."; \
			RUNNING=$$($(DC) ps -q 2>/dev/null | wc -l); \
			if [ "$$RUNNING" -ne "$$EXPECTED" ]; then \
				echo "Error: expected $$EXPECTED running services, found $$RUNNING. Refusing to prune."; \
				$(DC) ps -a; \
				exit 1; \
			fi; \
			NOT_UP=$$($(DC) ps -a --format '{{.Status}}' | grep -v '^Up' || true); \
			if [ -n "$$NOT_UP" ]; then \
				echo "Error: some containers are not up. Refusing to prune."; \
				$(DC) ps -a; \
				exit 1; \
			fi; \
			echo "✓ All services running. Pruning unused Docker resources..."; \
			docker system prune -af; \
			docker container prune -f; \
			docker image prune -af; \
			echo "✓ Prune completed"; \
		;; \
		help|"") \
			echo "docker:"; \
			echo "  make docker prune   Remove unused Docker containers and dangling images (only if all services are running)"; \
			echo "" \
		;; \
		*) \
			echo "Usage: make docker [prune|help]"; \
			exit 1; \
		;; \
	esac

# Prevent make from treating command arguments as targets
run test client github_files tvls beefy_db beefy_api beefy_cctp_api beefy_history logs restart ps start up info show failed-jobs drop-pending-packages sync trace schema load-package mcp drop drop-state reimport optimize cleanup-pipeline-state backup full incremental backup-status backup-restart restore version docs:
	@:

# Catch-all for any other resource/source names
%:
	@:

# Ensure required directories exist for bind mounts
ensure-dirs:
	@echo "Creating required data directories..."
	@for dir in $(DATA_DIRS); do \
		if [ ! -d "$$dir" ]; then \
			echo "Creating $$dir..."; \
			sudo mkdir -p "$$dir"; \
			sudo chmod 755 "$$dir"; \
		else \
			echo "Directory $$dir already exists"; \
		fi; \
	done
	@echo "✓ All required directories created"

