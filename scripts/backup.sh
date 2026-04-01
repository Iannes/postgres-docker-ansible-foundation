#!/usr/bin/env bash
# =============================================================================
# Smart Market — Database Backup
# =============================================================================
# Creates a point-in-time PostgreSQL dump using pg_dump in custom format (-Fc).
# The dump is written to BACKUP_DIR as a timestamped file.
#
# USAGE
#   ./scripts/backup.sh                  # standard backup + rotation
#   ./scripts/backup.sh --no-rotate      # backup only, skip rotation
#   ./scripts/backup.sh --help
#
# OUTPUT
#   ${BACKUP_DIR}/smartmarket_YYYYMMDD_HHMMSS.dump
#
# FORMAT
#   PostgreSQL custom format (-Fc, --compress=9).
#   Compact, supports parallel restore, and is portable across PG minor versions.
#   Restore with: pg_restore -d <dbname> <file>  OR  scripts/restore.sh <file>
#
# RETENTION
#   Keeps the ${BACKUP_RETENTION_COUNT} most recent backups. Older files are
#   removed. Set BACKUP_RETENTION_COUNT in .env. Default: 7.
#
# CONNECTION
#   pg_dump runs inside the container via the unix socket (local connection).
#   This requires no password and is unaffected by POSTGRES_HOST_AUTH_METHOD.
#   Output is streamed from the container to the host via 'docker exec' stdout.
#   A .tmp file is written first; it is renamed to .dump only on success.
#   A partial dump will never appear as a valid backup file.
#
# DISK NOTE
#   Dump size depends on data volume and compression. Monitor BACKUP_DIR:
#     du -sh ./backups/
#   On a pipeline DB, dumps can be large. Tune BACKUP_RETENTION_COUNT and
#   arrange off-host transfer (Phase 4) before running out of local disk.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

info()    { printf '[backup] %s\n' "$*"; }
success() { printf '[backup] \033[32m✓\033[0m %s\n' "$*"; }
warn()    { printf '[backup] \033[33m⚠\033[0m %s\n' "$*" >&2; }
die()     { printf '[backup] \033[31m✗ ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

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
: "${BACKUP_DIR:?BACKUP_DIR not set in .env}"
: "${BACKUP_RETENTION_COUNT:?BACKUP_RETENTION_COUNT not set in .env}"

# Resolve a relative BACKUP_DIR against the project root.
case "${BACKUP_DIR}" in
    ./*|../*)
        BACKUP_DIR="${PROJECT_ROOT}/${BACKUP_DIR#./}"
        ;;
esac

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

ROTATE=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-rotate) ROTATE=false; shift ;;
        --help|-h)
            sed -n '/^# ====/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
        *)
            die "Unknown argument: $1. Use --help for usage." ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

container_status="$(
    docker inspect --format='{{.State.Status}}' smartmarket_postgres 2>/dev/null || true
)"
[[ "${container_status}" == "running" ]] \
    || die "Container 'smartmarket_postgres' is not running. Start it before running a backup."

health_status="$(
    docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' \
        smartmarket_postgres 2>/dev/null || true
)"
[[ "${health_status}" == "healthy" ]] \
    || die "Container is not healthy (status: ${health_status}). Refusing to back up a potentially inconsistent database."

mkdir -p "${BACKUP_DIR}"

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="${BACKUP_DIR}/smartmarket_${TIMESTAMP}.dump"
BACKUP_TMP="${BACKUP_FILE}.tmp"

info "Database    : ${POSTGRES_DB}"
info "Destination : ${BACKUP_DIR}"
info "File        : smartmarket_${TIMESTAMP}.dump"
info "Starting dump..."

# pg_dump via docker exec:
#   - Connects via unix socket inside the container (local, trust auth — no password).
#   - Custom format (-Fc) with max compression.
#   - Output streams from container stdout to the host file via shell redirection.
#   - Written to .tmp first; renamed to .dump only on clean exit.
#
# Note: PGPASSWORD is not needed here. The unix socket connection uses pg_hba.conf
# 'local' auth, which defaults to 'trust' in the Docker image regardless of
# POSTGRES_HOST_AUTH_METHOD (which only affects host/TCP connections).
docker exec smartmarket_postgres \
    pg_dump \
        --username  "${POSTGRES_USER}" \
        --dbname    "${POSTGRES_DB}" \
        --format    custom \
        --compress  9 \
        --no-password \
    > "${BACKUP_TMP}"

mv "${BACKUP_TMP}" "${BACKUP_FILE}"

backup_size="$(du -sh "${BACKUP_FILE}" | cut -f1)"
success "Dump complete: smartmarket_${TIMESTAMP}.dump (${backup_size})"

# ---------------------------------------------------------------------------
# Rotation
# ---------------------------------------------------------------------------

if [[ "${ROTATE}" == true ]]; then
    info "Rotating old backups (retaining ${BACKUP_RETENTION_COUNT} most recent)..."

    mapfile -t all_backups < <(
        find "${BACKUP_DIR}" -maxdepth 1 -name 'smartmarket_*.dump' \
        | sort   # lexicographic sort on YYYYMMDD_HHMMSS prefix == chronological
    )

    total="${#all_backups[@]}"
    to_delete=$(( total - BACKUP_RETENTION_COUNT ))

    if [[ "${to_delete}" -gt 0 ]]; then
        for (( i=0; i<to_delete; i++ )); do
            info "  Removing old backup: $(basename "${all_backups[$i]}")"
            rm -f "${all_backups[$i]}"
        done
        success "Rotation complete: removed ${to_delete} file(s), retained ${BACKUP_RETENTION_COUNT}."
    else
        info "  No rotation needed (${total} backup(s) present, limit is ${BACKUP_RETENTION_COUNT})."
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "  Backup file   : ${BACKUP_FILE}"
echo "  Database      : ${POSTGRES_DB}"
echo "  Timestamp     : ${TIMESTAMP}"
echo "  Size          : ${backup_size}"
echo ""
echo "  To restore    : ./scripts/restore.sh ${BACKUP_FILE}"
echo ""
