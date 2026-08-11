#!/usr/bin/env bash
# ============================================================
# health-check.sh — Check all Supabase services & endpoints
#
# Usage:
#   bash scripts/health-check.sh
#   bash scripts/health-check.sh --quiet   # Only show failures
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

QUIET="${1:-}"
PASS=0
FAIL=0
WARN=0

# ─── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

ok()   { PASS=$((PASS+1)); [[ "$QUIET" != "--quiet" ]] && echo -e "  ${GREEN}✅ PASS${NC}  $*"; }
fail() { FAIL=$((FAIL+1)); echo -e "  ${RED}❌ FAIL${NC}  $*"; }
warn() { WARN=$((WARN+1)); echo -e "  ${YELLOW}⚠️  WARN${NC}  $*"; }

# Load .env for API keys
if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT_DIR/.env"
  set +a
fi

ANON_KEY="${ANON_KEY:-}"
API_URL="${SUPABASE_PUBLIC_URL:-https://api.aaryavtech.online}"

echo ""
echo -e "${BLUE}=============================================="
echo " Supabase Health Check — aaryavtech.online"
echo "==============================================${NC}"
echo ""

# ─── 1. System Resources ───────────────────────────────────
echo -e "${BLUE}── System Resources ──────────────────────────${NC}"

CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo "N/A")
echo "  CPU usage: ${CPU_USAGE}%"

MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
MEM_USED=$(free -m | awk '/^Mem:/{print $3}')
MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))
echo "  RAM: ${MEM_USED}MB / ${MEM_TOTAL}MB (${MEM_PCT}%)"
if [[ $MEM_PCT -gt 90 ]]; then
  warn "Memory usage critical: ${MEM_PCT}%"
elif [[ $MEM_PCT -gt 75 ]]; then
  warn "Memory usage high: ${MEM_PCT}%"
fi

DISK_PCT=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
DISK_AVAIL=$(df -h / | tail -1 | awk '{print $4}')
echo "  Disk: ${DISK_PCT}% used, ${DISK_AVAIL} available"
if [[ $DISK_PCT -gt 90 ]]; then
  fail "Disk usage critical: ${DISK_PCT}%"
elif [[ $DISK_PCT -gt 80 ]]; then
  warn "Disk usage high: ${DISK_PCT}%"
fi
echo ""

# ─── 2. Docker Container Status ────────────────────────────
echo -e "${BLUE}── Docker Containers ─────────────────────────${NC}"

declare -A CONTAINERS=(
  ["supabase-db"]="PostgreSQL database"
  ["supabase-auth"]="GoTrue auth service"
  ["supabase-rest"]="PostgREST API"
  ["supabase-realtime"]="Realtime WebSocket"
  ["supabase-storage"]="Storage API"
  ["supabase-studio"]="Supabase Studio"
  ["supabase-envoy"]="Envoy API gateway"
  ["supabase-meta"]="postgres-meta"
  ["supabase-edge-functions"]="Edge Functions"
  ["supabase-analytics"]="Analytics/Logflare"
  ["supabase-pooler"]="Supavisor pooler"
  ["supabase-imgproxy"]="Image proxy"
  ["supabase-vector"]="Log vector"
)

for container in "${!CONTAINERS[@]}"; do
  desc="${CONTAINERS[$container]}"
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")
  RUNNING=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "missing")

  if [[ "$RUNNING" == "missing" ]]; then
    fail "$desc ($container) — NOT FOUND"
  elif [[ "$RUNNING" != "running" ]]; then
    fail "$desc ($container) — Status: $RUNNING"
  elif [[ "$STATUS" == "healthy" ]] || [[ "$STATUS" == "" ]]; then
    ok "$desc ($container) — running"
  elif [[ "$STATUS" == "starting" ]]; then
    warn "$desc ($container) — starting (health check pending)"
  else
    fail "$desc ($container) — Health: $STATUS"
  fi
done
echo ""

# ─── 3. HTTP Endpoint Checks ───────────────────────────────
echo -e "${BLUE}── HTTP Endpoints ────────────────────────────${NC}"

check_url() {
  local url="$1"
  local desc="$2"
  local expected_status="${3:-200}"
  local extra_headers="${4:-}"

  local cmd="curl -sSf --max-time 10 -o /dev/null -w '%{http_code}'"
  if [[ -n "$extra_headers" ]]; then
    cmd="$cmd -H '$extra_headers'"
  fi

  local actual_status
  actual_status=$(eval "$cmd '$url'" 2>/dev/null || echo "000")

  if [[ "$actual_status" == "$expected_status" ]]; then
    ok "$desc — HTTP $actual_status"
  elif [[ "$actual_status" == "000" ]]; then
    fail "$desc — Connection failed ($url)"
  else
    fail "$desc — HTTP $actual_status (expected $expected_status) — $url"
  fi
}

# Internal checks (always run)
check_url "http://localhost:8000/health" "Envoy gateway (internal)"
check_url "http://localhost:9999/health" "Auth/GoTrue (internal)"
check_url "http://localhost:3000/api/platform/profile" "Studio (internal)"
check_url "http://localhost:8080/health" "postgres-meta (internal)"
check_url "http://localhost:5000/status" "Storage API (internal)"
check_url "http://localhost:4000/api/tenants/realtime-dev/health" "Realtime (internal)" "200" "Authorization: Bearer ${ANON_KEY}"

# External checks (requires DNS + Caddy running)
check_url "https://api.aaryavtech.online/rest/v1/" "REST API (external HTTPS)" "200" "apikey: ${ANON_KEY}"
check_url "https://api.aaryavtech.online/auth/v1/health" "Auth API (external HTTPS)"
check_url "https://supabase.aaryavtech.online" "Studio (external HTTPS)"
echo ""

# ─── 4. PostgreSQL Check ───────────────────────────────────
echo -e "${BLUE}── PostgreSQL ────────────────────────────────${NC}"

PG_STATUS=$(docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T db \
  pg_isready -U postgres -h localhost 2>&1 || echo "FAILED")

if echo "$PG_STATUS" | grep -q "accepting connections"; then
  ok "PostgreSQL accepting connections"
else
  fail "PostgreSQL: $PG_STATUS"
fi

PG_UPTIME=$(docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T db \
  psql -U postgres -t -c "SELECT now() - pg_postmaster_start_time();" 2>/dev/null | xargs || echo "N/A")
echo "  Uptime: $PG_UPTIME"

PG_CONNECTIONS=$(docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T db \
  psql -U postgres -t -c "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';" 2>/dev/null | xargs || echo "N/A")
echo "  Active connections: $PG_CONNECTIONS"

DB_SIZE=$(docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T db \
  psql -U postgres -t -c "SELECT pg_size_pretty(pg_database_size('postgres'));" 2>/dev/null | xargs || echo "N/A")
echo "  Database size: $DB_SIZE"
echo ""

# ─── 5. Caddy TLS Check ────────────────────────────────────
echo -e "${BLUE}── TLS / Caddy ───────────────────────────────${NC}"

for domain in supabase.aaryavtech.online api.aaryavtech.online; do
  CERT_EXPIRY=$(echo | openssl s_client -connect "${domain}:443" -servername "$domain" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null \
    | sed 's/notAfter=//' || echo "N/A")
  if [[ "$CERT_EXPIRY" == "N/A" ]]; then
    warn "Could not check TLS cert for $domain (DNS may not be set yet)"
  else
    echo "  $domain cert expires: $CERT_EXPIRY"
    ok "TLS certificate valid for $domain"
  fi
done
echo ""

# ─── 6. Backup Status ──────────────────────────────────────
echo -e "${BLUE}── Backups ───────────────────────────────────${NC}"

BACKUP_DIR="$PROJECT_DIR/backups"
LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/supabase_*.dump 2>/dev/null | head -1 || echo "")
if [[ -z "$LATEST_BACKUP" ]]; then
  warn "No backups found in $BACKUP_DIR — run scripts/backup.sh"
else
  BACKUP_AGE_DAYS=$(( ($(date +%s) - $(stat -c%Y "$LATEST_BACKUP")) / 86400 ))
  BACKUP_SIZE=$(du -sh "$LATEST_BACKUP" | cut -f1)
  echo "  Latest: $(basename "$LATEST_BACKUP") (${BACKUP_SIZE})"
  if [[ $BACKUP_AGE_DAYS -gt 1 ]]; then
    warn "Latest backup is ${BACKUP_AGE_DAYS} days old — consider running backup.sh"
  else
    ok "Latest backup is recent (${BACKUP_AGE_DAYS} day(s) old)"
  fi
fi
echo ""

# ─── Summary ───────────────────────────────────────────────
echo -e "${BLUE}=============================================="
echo " Health Check Summary"
echo "==============================================${NC}"
echo -e "  ${GREEN}✅ PASS${NC}: $PASS"
echo -e "  ${YELLOW}⚠️  WARN${NC}: $WARN"
echo -e "  ${RED}❌ FAIL${NC}: $FAIL"
echo ""

if [[ $FAIL -gt 0 ]]; then
  echo -e "  ${RED}Status: UNHEALTHY — $FAIL check(s) failed${NC}"
  exit 1
elif [[ $WARN -gt 0 ]]; then
  echo -e "  ${YELLOW}Status: DEGRADED — $WARN warning(s)${NC}"
  exit 0
else
  echo -e "  ${GREEN}Status: ALL HEALTHY${NC}"
  exit 0
fi
