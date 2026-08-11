#!/usr/bin/env bash
# ============================================================
# update.sh — Safe Supabase update procedure
#
# This script follows the official safe update procedure:
#   1. Backup database
#   2. Verify backup
#   3. Pull new images (from pinned versions in docker-compose.yml)
#   4. Restart services
#   5. Verify all services healthy
#
# Usage:
#   bash scripts/update.sh
#
# To update image versions, edit docker-compose.yml and change
# the image tags (e.g., supabase/studio:2026.08.03-sha-022b374)
# to newer pinned versions from the official Supabase changelog:
# https://github.com/supabase/supabase/releases
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✅${NC} $*"; }
warn(){ echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠️${NC}  $*"; }
err() { echo -e "${RED}[$(date '+%H:%M:%S')] ❌${NC} $*"; }

echo ""
echo -e "${BLUE}=============================================="
echo " Supabase Safe Update — aaryavtech.online"
echo "==============================================${NC}"
echo ""
warn "This will restart all Supabase services."
warn "Brief downtime is expected during container restarts."
echo ""
read -r -p "Proceed with update? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Update aborted."
  exit 0
fi

# ─── Step 1: Create pre-update backup ─────────────────────
log "Step 1/5: Creating pre-update database backup..."
if bash "$SCRIPT_DIR/backup.sh" --verify; then
  ok "Pre-update backup created and verified."
else
  err "Backup failed! Aborting update to protect your data."
  err "Fix backup issues before updating."
  exit 1
fi

# ─── Step 2: Pull new images ──────────────────────────────
log "Step 2/5: Pulling updated Docker images..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" pull
ok "Images pulled successfully."

# ─── Step 3: Check current state ──────────────────────────
log "Step 3/5: Noting current container versions..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" images

# ─── Step 4: Rolling restart ──────────────────────────────
log "Step 4/5: Restarting services..."

# Restart database first (if image changed), then wait for it
log "  Restarting database..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" up -d --no-deps db

log "  Waiting for database to become healthy..."
RETRIES=30
until docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T db \
  pg_isready -U postgres -h localhost &>/dev/null; do
  RETRIES=$((RETRIES - 1))
  if [[ $RETRIES -le 0 ]]; then
    err "Database did not become healthy after 150 seconds!"
    exit 1
  fi
  sleep 5
done
ok "Database is healthy."

# Restart all other services
log "  Restarting all other services..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" up -d

# ─── Step 5: Wait and verify ──────────────────────────────
log "Step 5/5: Waiting for services to stabilize (60 seconds)..."
sleep 60

log "Running health check..."
if bash "$SCRIPT_DIR/health-check.sh"; then
  ok ""
  ok "=============================================="
  ok " Update completed successfully!"
  ok "=============================================="
  ok ""
  ok " Verify manually:"
  ok "   1. Open https://supabase.aaryavtech.online"
  ok "   2. Check Studio loads and you can log in"
  ok "   3. Verify tables, auth, storage are intact"
  ok "   4. Test a realtime subscription"
else
  err ""
  err "Health check FAILED after update!"
  err ""
  err "To rollback, restore the pre-update backup:"
  LATEST_BACKUP=$(ls -t "$PROJECT_DIR/backups"/supabase_*.dump | head -1)
  err "  bash scripts/restore.sh $LATEST_BACKUP"
  err ""
  exit 1
fi

echo ""
echo "Updated container versions:"
docker compose -f "$PROJECT_DIR/docker-compose.yml" images
