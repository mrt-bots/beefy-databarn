# Pinned by digest (multi-arch index). Node 24 + glibc: beefy-history CLI runs TS directly and needs DuckDB's prebuilt binary.
ARG NODE_IMAGE=node:24.21.0-bookworm-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20
# github.com/mrt-bots/beefy-history — keep in sync with dlt/lib/beefy_history.py CLI_GIT_SHA
ARG BEEFY_HISTORY_GIT_SHA=79dd2fcc18d0373798eeeec9b9726dd876c39b89
ARG PNPM_VERSION=12.9.1

FROM ${NODE_IMAGE} AS beefy-history-cli
ARG BEEFY_HISTORY_GIT_SHA
ARG PNPM_VERSION
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN npm install -g --no-fund --no-audit "pnpm@${PNPM_VERSION}"
WORKDIR /opt/beefy-history
RUN git init \
    && git remote add origin https://github.com/mrt-bots/beefy-history.git \
    && git fetch --depth 1 origin "${BEEFY_HISTORY_GIT_SHA}" \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "${BEEFY_HISTORY_GIT_SHA}"
# Production deps of the CLI only (DuckDB parquet writer + oxc parser). Not the web/api/worker apps.
RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store \
    pnpm --filter "@beefy-history/core..." install --prod --frozen-lockfile --config.confirm-modules-purge=false

FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    ca-certificates \
    procps \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy dependency files first (for better layer caching)
COPY dlt/pyproject.toml dlt/uv.lock /app/dlt/

# Install Python dependencies using uv
WORKDIR /app/dlt
RUN uv sync --frozen

# Copy dlt project files
COPY dlt/ /app/dlt/

COPY infra/discord_webhook.py /app/infra/dlt/discord_webhook.py
COPY infra/dlt/scheduler.py infra/dlt/process.py infra/dlt/alerts.py infra/dlt/entrypoint.sh infra/dlt/set_dlt_env.sh /app/infra/dlt/
RUN chmod +x /app/infra/dlt/scheduler.py /app/infra/dlt/entrypoint.sh /app/infra/dlt/set_dlt_env.sh

# Pinned beefy-history CLI (Node 24). Git mirrors + store live on the /var/beefy-history volume.
COPY --from=beefy-history-cli /usr/local/bin/node /usr/local/bin/node
COPY --from=beefy-history-cli /opt/beefy-history /opt/beefy-history
ENV BEEFY_HISTORY_DIR=/opt/beefy-history \
    BEEFY_HISTORY_DATA_DIR=/var/beefy-history

# Set working directory to dlt project
WORKDIR /app/dlt

ENTRYPOINT ["/app/infra/dlt/entrypoint.sh"]
# Run the Python scheduler (runs every 5 minutes)
CMD ["uv", "run", "/app/infra/dlt/scheduler.py"]
