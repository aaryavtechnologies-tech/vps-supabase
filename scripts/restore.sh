#!/usr/bin/env bash
# ============================================================
# restore.sh — PostgreSQL restore from backup
#
# Usage:
#   bash scripts/restore.sh                     # Interactive: pick latest
#   bash scripts/restore.sh <backup-file.dump>  # Restore specific file
#
# WARNING: This DROPS and RECREATES the target database!
# Always verify the backup file before restoring to production.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load .env
if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT_DIR/.env"
  set +a
else
  echo "ERROR: .env not found." >&2
  exit 1
fi

BACKUP_DIR="${PROJECT_DIR}/backups"
DB="${POSTGRES_DB:-postgres}"

# ─── Determine backup file ─────────────────────────────────
if [[ -n "${1:-}" ]]; then
  BACKUP_FILE="$1"
else
  # Find the latest backup automatically
  BACKUP_FILE=$(ls -t "$BACKUP_DIR"/supabase_*.dump 2>/dev/null | head -1)
  if [[ -z "$BACKUP_FILE" ]]; then
    echo "ERROR: No backup files found in $BACKUP_DIR" >&2
    exit 1
  fi
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "ERROR: Backup file not found: $BACKUP_FILE" >&2
  exit 1
fi

BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)

# ─── Confirmation ──────────────────────────────────────────
echo "=============================================="
echo " ⚠️  PostgreSQL Restore"
echo "=============================================="
echo ""
echo " Backup file : $BACKUP_FILE"
echo " Backup size : $BACKUP_SIZE"
echo " Target DB   : $DB"
echo ""
echo " ⚠️  WARNING: This will OVERWRITE the current database!"
echo " All existing data will be replaced with the backup."
echo ""
read -r -p " Type 'yes' to confirm restore: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
  echo "Restore aborted. No changes made."
  exit 0
fi

echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting restore..."

# ─── Step 1: Create a safety backup of current state ──────
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating safety backup of current database..."
SAFETY_BACKUP="${BACKUP_DIR}/pre-restore-safety_$(date +%Y-%m-%d_%H-%M-%S).dump"
docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T db \
  pg_dump \
    --username=postgres \
    --dbname="$DB" \
    --format=custom \
    --compress=9 \
  > "$SAFETY_BACKUP"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Safety backup created: $SAFETY_BACKUP"

# ─── Step 2: Stop services that use the DB ────────────────
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Stopping dependent services..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" stop \
  auth rest realtime storage functions analytics supavisor studio api-gw

# ─── Step 3: Drop and recreate the database ───────────────
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Dropping existing database..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T db \
  psql --username=postgres --command="
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = '${DB}' AND pid <> pg_backend_pid();
  " postgres

docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T db \
  dropdb --username=postgres --if-exists "$DB"

docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T db \
  createdb --username=postgres "$DB"

# ─── Step 4: Restore ──────────────────────────────────────
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restoring backup..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T db \
  pg_restore \
    --username=postgres \
    --dbname="$DB" \
    --no-owner \
    --no-acl \
    --verbose \
  < "$BACKUP_FILE"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ Restore complete!"

# ─── Step 5: Restart all services ────────────────────────
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restarting all services..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" up -d

echo ""
echo "=============================================="
echo " ✅ Restore finished successfully!"
echo "=============================================="
echo ""
echo " Safety backup (pre-restore state):"
echo "   $SAFETY_BACKUP"
echo ""
echo " Run health check to verify:"
echo "   bash scripts/health-check.sh"
echo "=============================================="
