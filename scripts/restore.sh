#!/usr/bin/env bash
# =============================================================================
# Smart Market — Database Restore
# =============================================================================
# Restores the Smart Market database from a pg_dump custom-format backup.
#
# WARNING: DESTRUCTIVE OPERATION
#   This script drops and recreates the target database. All existing data
#   in the database will be permanently lost. There is no undo.
#
# USAGE
#   ./scripts/restore.sh <path-to-backup-file>
#
#   The backup file must be a custom-format (.dump) file created by
#   scripts/backup.sh or an equivalent pg_dump -Fc invocation.
#
# WHAT THIS SCRIPT DOES
#   1. Validates the backup file and container state
#   2. Requires explicit typed confirmation before proceeding
#   3. Terminates all active connections to the target database
#   4. Drops and recreates the target database
#   5. Copies the backup into the container (avoids volume mount assumptions)
#   6. Restores via pg_restore with --exit-on-error
#   7. Cleans up the temporary file inside the container
#   8. Verifies the restore by counting tables in the application schema
#
# ROLE BEHAVIOUR AFTER RESTORE
#   pg_restore recreates all objects owned by their original roles. It does NOT
#   create the roles themselves (roles are cluster-level, not database-level).
#   The roles (smartmarket_migrations, smartmarket_pipeline) must already exist
#   in the cluster before restoring. They persist across DROP/CREATE DATABASE.
#
#   If you are restoring into a brand-new cluster (fresh volume):
#     1. Run scripts/bootstrap-local.sh  (creates roles via initdb)
#     2. Then run scripts/restore.sh     (restores data into the existing DB)
#   Note: on a fresh cluster, bootstrap-local.sh creates an empty database.
#   Restoring over it is safe and will replace the empty DB with backup data.
#
# RECOVERY PROCEDURE (full disaster, fresh volume)
#   docker compose --project-name smartmarket \
#     -f docker/compose/docker-compose.yml down -v     # destroy volume
#   ./scripts/bootstrap-local.sh                       # recreate roles + empty DB
#   ./scripts/restore.sh ./backups/smartmarket_<ts>.dump
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

info()    { printf '[restore] %s\n' "$*"; }
success() { printf '[restore] \033[32m✓\033[0m %s\n' "$*"; }
warn()    { printf '[restore] \033[33m⚠\033[0m %s\n' "$*" >&2; }
die()     { printf '[restore] \033[31m✗ ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------

[[ -f "${ENV_FILE}" ]] || die ".env not found at ${ENV_FILE}"

set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

: "${POSTGRES_USER:?POSTGRES_USER not set in .env}"
: "${POSTGRES_DB:?POSTGRES_DB not set in .env}"

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

if [[ $# -ne 1 || "$1" == "--help" || "$1" == "-h" ]]; then
    echo ""
    echo "Usage: ./scripts/restore.sh <path-to-backup-file>"
    echo ""
    echo "  Backup files are in: ${BACKUP_DIR:-./backups}"
    echo ""
    echo "  Example:"
    echo "    ./scripts/restore.sh ./backups/smartmarket_20260401_120000.dump"
    echo ""
    [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && exit 0 || exit 1
fi

BACKUP_FILE="$1"

# Resolve relative paths against the project root.
case "${BACKUP_FILE}" in
    ./*|../*)
        BACKUP_FILE="${PROJECT_ROOT}/${BACKUP_FILE#./}"
        ;;
    [^/]*)
        BACKUP_FILE="${PROJECT_ROOT}/${BACKUP_FILE}"
        ;;
esac

[[ -f "${BACKUP_FILE}" ]] \
    || die "Backup file not found: ${BACKUP_FILE}"

backup_size="$(du -sh "${BACKUP_FILE}" | cut -f1)"
backup_basename="$(basename "${BACKUP_FILE}")"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

container_status="$(
    docker inspect --format='{{.State.Status}}' smartmarket_postgres 2>/dev/null || true
)"
[[ "${container_status}" == "running" ]] \
    || die "Container 'smartmarket_postgres' is not running. Run bootstrap-local.sh first."

health_status="$(
    docker inspect \
        --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' \
        smartmarket_postgres 2>/dev/null || true
)"
if [[ "${health_status}" != "healthy" ]]; then
    warn "Container health status is '${health_status}' (expected 'healthy')."
    warn "Proceeding, but the database may not be fully ready."
fi

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------

echo ""
echo "  *** WARNING: DESTRUCTIVE OPERATION ***"
echo ""
echo "  This will PERMANENTLY DROP and RECREATE:"
echo ""
echo "    Database  :  ${POSTGRES_DB}"
echo "    Cluster   :  smartmarket_postgres (container)"
echo ""
echo "  Restoring from:"
echo ""
echo "    File      :  ${backup_basename}"
echo "    Size      :  ${backup_size}"
echo ""
echo "  ALL EXISTING DATA IN '${POSTGRES_DB}' WILL BE LOST."
echo "  There is no undo. Ensure you have a current backup before proceeding."
echo ""
read -r -p "  Type the database name to confirm restore: " confirm_name
echo ""

[[ "${confirm_name}" == "${POSTGRES_DB}" ]] \
    || die "Confirmation did not match '${POSTGRES_DB}'. Restore aborted."

# ---------------------------------------------------------------------------
# Copy backup into container
# ---------------------------------------------------------------------------

CONTAINER_TMP="/tmp/smartmarket_restore_$(date +%s).dump"

info "Copying backup into container..."
docker cp "${BACKUP_FILE}" "smartmarket_postgres:${CONTAINER_TMP}"

# Ensure temp file is removed from the container even if restore fails.
cleanup_container_tmp() {
    docker exec smartmarket_postgres rm -f "${CONTAINER_TMP}" 2>/dev/null || true
}
trap cleanup_container_tmp EXIT

# ---------------------------------------------------------------------------
# Terminate active connections
# ---------------------------------------------------------------------------

info "Terminating active connections to '${POSTGRES_DB}'..."

docker exec smartmarket_postgres psql \
    --username "${POSTGRES_USER}" \
    --dbname   postgres \
    --quiet    --no-align --tuples-only \
    -c "SELECT pg_terminate_backend(pid)
        FROM   pg_stat_activity
        WHERE  datname = '${POSTGRES_DB}'
          AND  pid <> pg_backend_pid();"

# ---------------------------------------------------------------------------
# Drop and recreate the database
# ---------------------------------------------------------------------------

info "Dropping database '${POSTGRES_DB}'..."
docker exec smartmarket_postgres psql \
    --username "${POSTGRES_USER}" \
    --dbname   postgres \
    --quiet \
    -c "DROP DATABASE IF EXISTS \"${POSTGRES_DB}\";"

info "Recreating database '${POSTGRES_DB}'..."
docker exec smartmarket_postgres psql \
    --username "${POSTGRES_USER}" \
    --dbname   postgres \
    --quiet \
    -c "CREATE DATABASE \"${POSTGRES_DB}\" OWNER \"${POSTGRES_USER}\";"

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------

info "Running pg_restore (--exit-on-error)..."

# --exit-on-error: abort immediately on any restore error rather than continuing
# and leaving the database in a partially-restored state.
# --no-password: connection is via unix socket (local auth, no password needed).
docker exec smartmarket_postgres \
    pg_restore \
        --username      "${POSTGRES_USER}" \
        --dbname        "${POSTGRES_DB}" \
        --no-password \
        --exit-on-error \
        "${CONTAINER_TMP}"

# cleanup_container_tmp runs via trap on EXIT.

# ---------------------------------------------------------------------------
# Post-restore verification
# ---------------------------------------------------------------------------

info "Verifying restore..."

table_count="$(
    docker exec smartmarket_postgres \
        psql \
            --username "${POSTGRES_USER}" \
            --dbname   "${POSTGRES_DB}" \
            --no-align --tuples-only --quiet \
            -c "SELECT count(*)
                FROM   pg_tables
                WHERE  schemaname = 'smartmarket';" \
    | tr -d '[:space:]'
)"

success "Restore complete."
echo ""
echo "  Restored from  : ${backup_basename}"
echo "  Database       : ${POSTGRES_DB}"
echo "  Tables in 'smartmarket' schema : ${table_count}"
echo ""

# Remind operator to verify role grants if restoring to a different cluster.
echo "  Post-restore checklist:"
echo "    [ ] Verify application roles exist: ./scripts/db-connect.sh  then  \\du"
echo "    [ ] Run a smoke query as smartmarket_pipeline to confirm grants are intact"
echo "    [ ] If roles are missing, re-run bootstrap-local.sh, then restore again"
echo ""
