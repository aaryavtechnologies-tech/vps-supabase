#!/usr/bin/env bash
# ============================================================
# backup.sh — Automated PostgreSQL backup for Supabase
#
# Usage:
#   bash scripts/backup.sh              # Manual backup
#   bash scripts/backup.sh --verify     # Backup + verify
#
# Cron (daily at 2 AM):
#   0 2 * * * /opt/supabase/scripts/backup.sh >> /var/log/supabase-backup.log 2>&1
#
# Disk space guide:
#   Reserve at least 3x your current DB size for backups.
#   With 7-day retention: 7x daily backup size.
#   Monitor with: du -sh /opt/supabase/backups/
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load .env
if [[ -f "$PROJECT_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "$PROJECT_DIR/.env"
  set +a
else
  echo "ERROR: .env not found at $PROJECT_DIR/.env" >&2
  exit 1
fi

# ─── Configuration ─────────────────────────────────────────
BACKUP_DIR="${PROJECT_DIR}/backups"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_FILE="${BACKUP_DIR}/supabase_${TIMESTAMP}.dump"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')] BACKUP"

# ─── Setup ─────────────────────────────────────────────────
mkdir -p "$BACKUP_DIR"

echo "$LOG_PREFIX Starting PostgreSQL backup..."
echo "$LOG_PREFIX Timestamp: $TIMESTAMP"
echo "$LOG_PREFIX Output: $BACKUP_FILE"

# ─── Run pg_dump inside the DB container ───────────────────
# Uses custom format (-Fc) for best compression and selective restore
docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T db \
  pg_dump \
    --username=postgres \
    --dbname="${POSTGRES_DB:-postgres}" \
    --format=custom \
    --compress=9 \
    --no-password \
  > "$BACKUP_FILE"

BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
echo "$LOG_PREFIX Backup complete. Size: $BACKUP_SIZE"

# ─── Verify backup integrity ───────────────────────────────
if [[ "${1:-}" == "--verify" ]] || [[ "${BACKUP_VERIFY:-false}" == "true" ]]; then
  echo "$LOG_PREFIX Verifying backup integrity..."
  docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T db \
    pg_restore \
      --list \
      --username=postgres \
      /dev/stdin < "$BACKUP_FILE" > /dev/null
  echo "$LOG_PREFIX ✅ Backup verified successfully."
fi

# ─── Cleanup old backups ───────────────────────────────────
echo "$LOG_PREFIX Removing backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -name "supabase_*.dump" -mtime +"$RETENTION_DAYS" -delete
REMAINING=$(ls "$BACKUP_DIR"/supabase_*.dump 2>/dev/null | wc -l)
echo "$LOG_PREFIX Retention cleanup done. ${REMAINING} backup(s) remaining."

# ─── Optional: Upload to remote storage ────────────────────
# Uncomment and configure one of the following:

# Option A: Rclone (supports S3, Google Drive, Backblaze B2, etc.)
# Install: https://rclone.org/install/
# Configure: rclone config (creates ~/.config/rclone/rclone.conf)
#
# RCLONE_REMOTE="my-remote:supabase-backups"
# if command -v rclone &>/dev/null; then
#   echo "$LOG_PREFIX Uploading to remote: $RCLONE_REMOTE"
#   rclone copy "$BACKUP_FILE" "$RCLONE_REMOTE/"
#   echo "$LOG_PREFIX ✅ Remote upload complete."
# fi

# Option B: AWS S3 (requires awscli + credentials)
# S3_BUCKET="s3://your-bucket-name/supabase-backups"
# if command -v aws &>/dev/null; then
#   aws s3 cp "$BACKUP_FILE" "${S3_BUCKET}/"
#   echo "$LOG_PREFIX ✅ S3 upload complete."
# fi

# Option C: SCP to another server
# REMOTE_HOST="backup-server.example.com"
# REMOTE_PATH="/backups/supabase/"
# REMOTE_USER="backupuser"
# scp "$BACKUP_FILE" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"

echo "$LOG_PREFIX ✅ Backup job finished successfully."
echo "$LOG_PREFIX Backup file: $BACKUP_FILE (${BACKUP_SIZE})"

# ─── Summary ───────────────────────────────────────────────
echo ""
echo "Backup storage usage:"
du -sh "$BACKUP_DIR" 2>/dev/null || true
echo ""
echo "Available disk space:"
df -h "$BACKUP_DIR" | tail -1
