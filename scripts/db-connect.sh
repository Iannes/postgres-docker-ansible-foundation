#!/usr/bin/env bash
# =============================================================================
# Smart Market — Database Connection Helper
# =============================================================================
# Opens a psql session against the Smart Market PostgreSQL database.
#
# MODES
#   local   (default) — docker exec into the running container.
#                       Uses the unix socket inside the container; no password
#                       required. The intended local operator access model.
#
#   remote            — opens an SSH tunnel to the production host, then
#                       launches psql locally through the tunnel.
#                       Requires psql installed locally and SSH access to host.
#
# USAGE
#   ./scripts/db-connect.sh
#   ./scripts/db-connect.sh --remote user@host
#   ./scripts/db-connect.sh --remote user@host:2222   # custom SSH port
#   ./scripts/db-connect.sh --role migrations          # connect as migrations role
#   ./scripts/db-connect.sh --help
#
# REMOTE ACCESS MODEL
#   PostgreSQL is never exposed publicly. The only supported remote access path
#   is an SSH tunnel: localhost:TUNNEL_PORT -> 127.0.0.1:5432 on the server.
#   This requires SSH access to the server and psql installed locally.
#
# OPTIONS
#   --remote  user@host[:ssh-port]   open SSH tunnel and connect through it
#   --role    migrations|pipeline    connect as an application role (prompts for password)
#   --help                           show this help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '[db-connect] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------

[[ -f "${ENV_FILE}" ]] \
    || die ".env not found at ${ENV_FILE}. Run scripts/bootstrap-local.sh first."

set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

: "${POSTGRES_USER:?POSTGRES_USER not set in .env}"
: "${POSTGRES_DB:?POSTGRES_DB not set in .env}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD not set in .env}"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

MODE="local"
REMOTE_TARGET=""
CONNECT_ROLE="${POSTGRES_USER}"
CONNECT_PASSWORD="${POSTGRES_PASSWORD}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote)
            MODE="remote"
            REMOTE_TARGET="${2:?--remote requires a user@host[:port] argument}"
            shift 2
            ;;
        --role)
            case "${2:-}" in
                migrations)
                    CONNECT_ROLE="smartmarket_migrations"
                    CONNECT_PASSWORD="${SMARTMARKET_MIGRATIONS_PASSWORD:?SMARTMARKET_MIGRATIONS_PASSWORD not set in .env}"
                    ;;
                pipeline)
                    CONNECT_ROLE="smartmarket_pipeline"
                    CONNECT_PASSWORD="${SMARTMARKET_PIPELINE_PASSWORD:?SMARTMARKET_PIPELINE_PASSWORD not set in .env}"
                    ;;
                *)
                    die "--role must be 'migrations' or 'pipeline' (got: '${2:-}')"
                    ;;
            esac
            shift 2
            ;;
        --help|-h)
            sed -n '/^# ====/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            die "Unknown argument: $1. Use --help for usage."
            ;;
    esac
done

# ---------------------------------------------------------------------------
# LOCAL mode: docker exec psql via unix socket
# ---------------------------------------------------------------------------

if [[ "${MODE}" == "local" ]]; then

    container_status="$(
        docker inspect \
            --format='{{.State.Status}}' \
            smartmarket_postgres 2>/dev/null || true
    )"

    [[ "${container_status}" == "running" ]] \
        || die "Container 'smartmarket_postgres' is not running. Run scripts/bootstrap-local.sh."

    if [[ "${CONNECT_ROLE}" == "${POSTGRES_USER}" ]]; then
        # Superuser via unix socket: trust auth, no password needed.
        info "Connecting as superuser via unix socket (no password required)"
        info "Database: ${POSTGRES_DB}  |  User: ${POSTGRES_USER}"
        echo ""
        exec docker exec -it smartmarket_postgres \
            psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"
    else
        # Application role via TCP to localhost. The container port must be
        # published (docker-compose.override.yml) for this to work locally.
        local_port="${POSTGRES_LOCAL_PORT:-5432}"
        info "Connecting as ${CONNECT_ROLE} via 127.0.0.1:${local_port}"
        info "Database: ${POSTGRES_DB}"
        echo ""
        PGPASSWORD="${CONNECT_PASSWORD}" exec psql \
            -h 127.0.0.1 \
            -p "${local_port}" \
            -U "${CONNECT_ROLE}" \
            -d "${POSTGRES_DB}"
    fi
fi

# ---------------------------------------------------------------------------
# REMOTE mode: SSH tunnel + local psql
# ---------------------------------------------------------------------------

if [[ "${MODE}" == "remote" ]]; then

    command -v psql >/dev/null 2>&1 \
        || die "psql not found locally. Install it: apt install postgresql-client  OR  brew install libpq"
    command -v ssh >/dev/null 2>&1 \
        || die "ssh not found."

    # Parse optional SSH port from user@host:port syntax.
    if [[ "${REMOTE_TARGET}" =~ ^(.+):([0-9]+)$ ]]; then
        SSH_USER_HOST="${BASH_REMATCH[1]}"
        SSH_PORT="${BASH_REMATCH[2]}"
    else
        SSH_USER_HOST="${REMOTE_TARGET}"
        SSH_PORT="22"
    fi

    # Use a high local port to avoid conflicts with a local Postgres instance.
    TUNNEL_LOCAL_PORT="${POSTGRES_LOCAL_PORT:-15432}"
    # Avoid port collision: if POSTGRES_LOCAL_PORT is 5432 (the default local
    # dev port), bump the tunnel to a distinct port.
    if [[ "${TUNNEL_LOCAL_PORT}" == "5432" ]]; then
        TUNNEL_LOCAL_PORT="15432"
    fi

    info "Opening SSH tunnel: localhost:${TUNNEL_LOCAL_PORT} -> 127.0.0.1:5432 on ${SSH_USER_HOST}"
    info "(SSH port: ${SSH_PORT})"
    echo ""

    # Open background tunnel. Kill it when this script exits.
    ssh -f -N \
        -p "${SSH_PORT}" \
        -L "${TUNNEL_LOCAL_PORT}:127.0.0.1:5432" \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o StrictHostKeyChecking=accept-new \
        "${SSH_USER_HOST}"

    # Find the SSH process we just spawned so we can clean it up.
    SSH_PID=""
    for _ in 1 2 3; do
        SSH_PID="$(pgrep -n -f "ssh.*${TUNNEL_LOCAL_PORT}:127.0.0.1:5432" 2>/dev/null || true)"
        [[ -n "${SSH_PID}" ]] && break
        sleep 1
    done

    cleanup() {
        if [[ -n "${SSH_PID}" ]]; then
            kill "${SSH_PID}" 2>/dev/null || true
            info "SSH tunnel closed."
        fi
    }
    trap cleanup EXIT INT TERM

    info "Tunnel established (PID ${SSH_PID}). Launching psql..."
    info "Host: 127.0.0.1:${TUNNEL_LOCAL_PORT}  |  Database: ${POSTGRES_DB}  |  User: ${CONNECT_ROLE}"
    echo ""

    PGPASSWORD="${CONNECT_PASSWORD}" psql \
        -h 127.0.0.1 \
        -p "${TUNNEL_LOCAL_PORT}" \
        -U "${CONNECT_ROLE}" \
        -d "${POSTGRES_DB}"
fi
