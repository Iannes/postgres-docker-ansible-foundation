#!/usr/bin/env bash
# =============================================================================
# Smart Market — Local Bootstrap
# =============================================================================
# First-run setup for the local Docker PostgreSQL environment.
# Safe to re-run: checks state before taking any action.
#
# USAGE
#   ./scripts/bootstrap-local.sh
#
# WHAT IT DOES
#   1. Verifies Docker and Docker Compose v2 are available
#   2. Verifies .env exists and has no placeholder credentials
#   3. Pulls the PostgreSQL image
#   4. Starts the stack (base + local override)
#   5. Waits for the healthcheck to pass
#   6. Runs a smoke-test query to confirm connectivity
#
# PREREQUISITES
#   - Docker Engine installed and running
#   - Docker Compose v2  ('docker compose', not 'docker-compose')
#   - .env at the project root (copy from env/.env.example and fill in values)
#
# FIRST TIME
#   cp env/.env.example .env
#   # edit .env — replace all CHANGEME_ values
#   ./scripts/bootstrap-local.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_BASE="${PROJECT_ROOT}/docker/compose/docker-compose.yml"
COMPOSE_OVERRIDE="${PROJECT_ROOT}/docker/compose/docker-compose.override.yml"
ENV_FILE="${PROJECT_ROOT}/.env"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

info()    { printf '[bootstrap] %s\n' "$*"; }
success() { printf '[bootstrap] \033[32m✓\033[0m %s\n' "$*"; }
warn()    { printf '[bootstrap] \033[33m⚠\033[0m %s\n' "$*" >&2; }
die()     { printf '[bootstrap] \033[31m✗ ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Dependency checks
# ---------------------------------------------------------------------------

info "Checking prerequisites..."

command -v docker >/dev/null 2>&1 \
    || die "Docker is not installed or not in PATH."

docker compose version >/dev/null 2>&1 \
    || die "'docker compose' (v2) not found. Ensure Docker Desktop or the Compose plugin is installed."

docker info >/dev/null 2>&1 \
    || die "Docker daemon is not running. Start Docker and retry."

success "Docker $(docker --version | awk '{print $3}' | tr -d ',') and Compose $(docker compose version --short) are available."

# ---------------------------------------------------------------------------
# 2. Environment file checks
# ---------------------------------------------------------------------------

info "Checking .env..."

if [[ ! -f "${ENV_FILE}" ]]; then
    warn ".env not found at: ${ENV_FILE}"
    echo ""
    echo "  Create it from the template:"
    echo "    cp env/.env.example .env"
    echo ""
    echo "  Then replace all CHANGEME_ values. Generate passwords with:"
    echo "    openssl rand -base64 32"
    echo ""
    die "Refusing to start without a .env file."
fi

# Check that required variables are present and not still holding placeholder values.
required_vars=(
    POSTGRES_DB
    POSTGRES_USER
    POSTGRES_PASSWORD
    POSTGRES_HOST_AUTH_METHOD
    SMARTMARKET_MIGRATIONS_PASSWORD
    SMARTMARKET_PIPELINE_PASSWORD
)

placeholder_found=false

while IFS= read -r line || [[ -n "${line}" ]]; do
    # Strip leading whitespace; skip comments and blank lines.
    line="${line#"${line%%[![:space:]]*}"}"
    [[ "${line}" =~ ^#  ]] && continue
    [[ -z "${line}"     ]] && continue
    [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    # Strip inline comments and surrounding quotes from value (best-effort).
    value="${value%%#*}"
    value="${value//\"/}"
    value="${value//\'/}"
    value="${value// /}"

    for var in "${required_vars[@]}"; do
        if [[ "${key}" == "${var}" && "${value}" == CHANGEME_* ]]; then
            warn "Placeholder not replaced: ${key}"
            placeholder_found=true
        fi
    done
done < "${ENV_FILE}"

if [[ "${placeholder_found}" == true ]]; then
    echo ""
    echo "  Edit .env and replace all CHANGEME_ values with real credentials."
    echo "  Generate passwords: openssl rand -base64 32"
    echo ""
    die "Refusing to start with placeholder credentials."
fi

success ".env is ready."

# ---------------------------------------------------------------------------
# 3. Pull image
# ---------------------------------------------------------------------------

info "Pulling PostgreSQL image (no-op if already cached)..."

docker compose \
    --project-name smartmarket \
    --env-file    "${ENV_FILE}" \
    -f            "${COMPOSE_BASE}" \
    pull --quiet

success "Image is ready."

# ---------------------------------------------------------------------------
# 4. Start the stack
# ---------------------------------------------------------------------------

info "Starting PostgreSQL..."

docker compose \
    --project-name smartmarket \
    --env-file    "${ENV_FILE}" \
    -f            "${COMPOSE_BASE}" \
    -f            "${COMPOSE_OVERRIDE}" \
    up --detach

# ---------------------------------------------------------------------------
# 5. Wait for healthy
# ---------------------------------------------------------------------------

info "Waiting for PostgreSQL healthcheck to pass..."

max_attempts=40   # 40 × 3 s = 120 s max
attempt=0

while true; do
    health="$(docker inspect \
                --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
                smartmarket_postgres 2>/dev/null || true)"

    if [[ "${health}" == "healthy" ]]; then
        echo ""
        break
    fi

    attempt=$(( attempt + 1 ))
    if [[ "${attempt}" -ge "${max_attempts}" ]]; then
        echo ""
        warn "PostgreSQL did not become healthy after $(( max_attempts * 3 )) seconds."
        echo ""
        echo "  Inspect container logs:"
        echo "    docker logs smartmarket_postgres"
        echo ""
        echo "  Check container status:"
        echo "    docker inspect smartmarket_postgres | jq '.[0].State'"
        echo ""
        die "Health check timed out."
    fi

    printf "."
    sleep 3
done

success "PostgreSQL is healthy."

# ---------------------------------------------------------------------------
# 6. Connectivity smoke test
# ---------------------------------------------------------------------------

info "Running connectivity smoke test..."

# Load vars for the check. set -a exports all sourced variables.
set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

pg_version="$(
    docker exec smartmarket_postgres \
        psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
             -c "SELECT version();" \
             --no-align --tuples-only --quiet \
    | head -1
)"

[[ "${pg_version}" == *"PostgreSQL"* ]] \
    || die "Connected but version query returned unexpected output: ${pg_version}"

success "Smoke test passed: ${pg_version%%,*}"

# Verify application roles were created by initdb.
roles_found="$(
    docker exec smartmarket_postgres \
        psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
             -c "SELECT string_agg(rolname, ', ' ORDER BY rolname)
                 FROM pg_catalog.pg_roles
                 WHERE rolname IN ('smartmarket_migrations', 'smartmarket_pipeline');" \
             --no-align --tuples-only --quiet \
    | head -1
)"

if [[ "${roles_found}" == *"smartmarket_migrations"* && "${roles_found}" == *"smartmarket_pipeline"* ]]; then
    success "Application roles present: ${roles_found}"
else
    warn "Expected roles not found (got: '${roles_found}')."
    warn "This is normal if the volume already existed before these roles were added."
    warn "To re-run role provisioning: destroy the volume and restart."
    warn "  docker compose --project-name smartmarket -f docker/compose/docker-compose.yml down -v"
    warn "  ./scripts/bootstrap-local.sh"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "  ============================================================"
echo "  Smart Market — PostgreSQL is running"
echo "  ============================================================"
echo ""
echo "  Container   :  smartmarket_postgres"
echo "  Database    :  ${POSTGRES_DB}"
echo "  Local port  :  127.0.0.1:${POSTGRES_LOCAL_PORT:-5432}"
echo "  Image       :  postgres:${POSTGRES_IMAGE_TAG:-16.3}"
echo ""
echo "  Connect     :  ./scripts/db-connect.sh"
echo "  Backup      :  ./scripts/backup.sh"
echo "  Stop        :  docker compose --project-name smartmarket \\"
echo "                   -f docker/compose/docker-compose.yml down"
echo ""
echo "  See docs/bootstrap-local.md for full operational notes."
echo ""
