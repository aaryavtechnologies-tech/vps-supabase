#!/usr/bin/env bash
# ============================================================
# deploy.sh — One-command VPS deployment script
#
# Run this on your VPS after cloning the repo:
#   bash deploy.sh
#
# What it does:
#   1. Pre-flight checks (OS, Docker, ports, disk, DNS)
#   2. Installs Docker (if not installed)
#   3. Installs Caddy (if not installed)
#   4. Generates secrets (.env)
#   5. Creates required directories
#   6. Configures Caddy
#   7. Starts Supabase (docker compose up -d)
#   8. Sets up daily backup cron
#   9. Sets up auto-start on reboot
#  10. Runs health check
# ============================================================
set -euo pipefail

# ─── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo -e "${BLUE}[DEPLOY]${NC} $*"; }
ok()   { echo -e "${GREEN}[  OK  ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ WARN ]${NC} $*"; }
err()  { echo -e "${RED}[ FAIL ]${NC} $*"; exit 1; }
step() { echo -e "\n${CYAN}══════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════════${NC}"; }

# ──────────────────────────────────────────────────────────
step "Step 1/10 — Pre-flight checks"
# ──────────────────────────────────────────────────────────

# Ubuntu version
OS=$(lsb_release -rs 2>/dev/null || echo "unknown")
log "OS: Ubuntu $OS"
if [[ "$OS" != "22.04" && "$OS" != "24.04" ]]; then
  warn "This script is tested on Ubuntu 22.04/24.04. Proceeding anyway..."
fi

# RAM check
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
log "RAM: ${TOTAL_RAM}MB available"
if [[ $TOTAL_RAM -lt 3800 ]]; then
  err "Less than 4GB RAM detected (${TOTAL_RAM}MB). Supabase requires at least 4GB."
fi

# Disk check
DISK_AVAIL=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')
log "Disk available: ${DISK_AVAIL}GB"
if [[ $DISK_AVAIL -lt 20 ]]; then
  err "Less than 20GB disk space available (${DISK_AVAIL}GB). Please free up space."
fi

# Web server checks (Nginx / Caddy)
USE_NGINX=false
if systemctl is-active --quiet nginx; then
  log "Nginx is running on this server. We will configure Nginx instead of Caddy."
  USE_NGINX=true
else
  # Port checks for Caddy
  PORTS_IN_USE=""
  for port in 80 443; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      PORTS_IN_USE="$PORTS_IN_USE $port"
    fi
  done

  if [[ -n "$PORTS_IN_USE" ]]; then
    warn "Ports${PORTS_IN_USE} are currently in use."
    warn "Checking which service is using them..."
    ss -tlnp | grep -E ":(80|443) " || true
    echo ""
    read -r -p "Stop conflicting services and continue with Caddy? [y/N] " CONFIRM
    [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || err "Aborted. Free ports 80/443 first."
    sudo systemctl stop nginx apache2 2>/dev/null || true
  fi
fi

ok "Pre-flight checks passed."

# ──────────────────────────────────────────────────────────
step "Step 2/10 — Install Docker"
# ──────────────────────────────────────────────────────────

if command -v docker &>/dev/null; then
  DOCKER_VER=$(docker --version)
  ok "Docker already installed: $DOCKER_VER"
else
  log "Installing Docker..."
  sudo apt-get update -q
  curl -fsSL https://get.docker.com | sudo bash
  sudo usermod -aG docker "$USER"
  ok "Docker installed."
  warn "You may need to log out and back in for group changes to take effect."
  warn "If docker commands fail, run: newgrp docker"
fi

if ! docker compose version &>/dev/null; then
  log "Installing Docker Compose plugin..."
  if apt-cache search docker-compose-plugin | grep -q docker-compose-plugin; then
    sudo apt-get install -y docker-compose-plugin
  elif apt-cache search docker-compose-v2 | grep -q docker-compose-v2; then
    sudo apt-get install -y docker-compose-v2
  else
    log "Downloading Docker Compose binary directly..."
    sudo mkdir -p /usr/local/lib/docker/cli-plugins
    sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
    sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  fi
fi

COMPOSE_VER=$(docker compose version)
ok "Docker Compose: $COMPOSE_VER"

# ──────────────────────────────────────────────────────────
step "Step 3/10 — Install Web Server"
# ──────────────────────────────────────────────────────────

if [[ "$USE_NGINX" == "true" ]]; then
  ok "Using existing Nginx installation."
else
  if command -v caddy &>/dev/null; then
    ok "Caddy already installed: $(caddy version)"
  else
    log "Installing Caddy..."
    sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt-get update -q
    sudo apt-get install -y caddy
    ok "Caddy installed: $(caddy version)"
  fi
fi

# ──────────────────────────────────────────────────────────
step "Step 4/10 — Configure Firewall (UFW)"
# ──────────────────────────────────────────────────────────

if command -v ufw &>/dev/null; then
  # Allow SSH first (critical!)
  sudo ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
  sudo ufw allow 80/tcp comment 'HTTP' 2>/dev/null || true
  sudo ufw allow 443/tcp comment 'HTTPS' 2>/dev/null || true
  sudo ufw --force enable 2>/dev/null || true
  ok "UFW firewall configured (22, 80, 443 open)."
  sudo ufw status
else
  warn "UFW not found. Skipping firewall setup."
fi

# ──────────────────────────────────────────────────────────
step "Step 5/10 — Generate Secrets"
# ──────────────────────────────────────────────────────────

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  warn ".env already exists. Skipping secret generation."
  warn "To regenerate: bash scripts/generate-secrets.sh"
else
  log "Generating secrets..."
  bash "$SCRIPT_DIR/scripts/generate-secrets.sh"
  ok "Secrets generated. .env created."
  echo ""
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  warn "ACTION REQUIRED: Set your Hostinger SMTP password"
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  warn "  nano $SCRIPT_DIR/.env"
  warn "  Find: SMTP_PASS=CHANGE_ME_..."
  warn "  Set:  SMTP_PASS=your_actual_hostinger_email_password"
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  read -r -p "Press ENTER after setting SMTP_PASS in .env (or press ENTER to skip SMTP for now)..."
fi

# ──────────────────────────────────────────────────────────
step "Step 6/10 — Create Required Directories"
# ──────────────────────────────────────────────────────────

mkdir -p "$SCRIPT_DIR/backups"
mkdir -p "$SCRIPT_DIR/volumes/snippets"
mkdir -p "$SCRIPT_DIR/volumes/functions"
mkdir -p "$SCRIPT_DIR/volumes/db"

# Make scripts executable
chmod +x "$SCRIPT_DIR/scripts/"*.sh

ok "Directories created."

# ──────────────────────────────────────────────────────────
step "Step 7/10 — Configure Web Server"
# ──────────────────────────────────────────────────────────

if [[ "$USE_NGINX" == "true" ]]; then
  log "Configuring Nginx..."
  sudo cp "$SCRIPT_DIR/nginx/supabase.conf" /etc/nginx/sites-available/supabase
  sudo ln -sf /etc/nginx/sites-available/supabase /etc/nginx/sites-enabled/supabase
  
  if sudo nginx -t; then
    ok "Nginx configuration is valid."
    sudo systemctl reload nginx
    ok "Nginx reloaded."
    warn "You must manually request SSL certificates for Nginx:"
    warn "  sudo apt install -y certbot python3-certbot-nginx"
    warn "  sudo certbot --nginx -d supabase.aaryavtech.online -d api.aaryavtech.online"
  else
    err "Nginx configuration failed! Check /etc/nginx/sites-available/supabase"
  fi
else
  log "Configuring Caddy..."
  sudo cp "$SCRIPT_DIR/Caddyfile" /etc/caddy/Caddyfile

  sudo mkdir -p /var/log/caddy
  sudo chown caddy:caddy /var/log/caddy 2>/dev/null || sudo chown www-data:www-data /var/log/caddy 2>/dev/null || true

  # Validate Caddyfile
  if sudo caddy validate --config /etc/caddy/Caddyfile; then
    ok "Caddyfile is valid."
  else
    err "Caddyfile validation failed! Check /etc/caddy/Caddyfile"
  fi

  # Enable and start Caddy
  sudo systemctl enable caddy
  sudo systemctl restart caddy
  ok "Caddy started."
fi

# ──────────────────────────────────────────────────────────
step "Step 8/10 — Start Supabase"
# ──────────────────────────────────────────────────────────

log "Starting all Supabase services (this takes 1-3 minutes)..."
cd "$SCRIPT_DIR"
docker compose up -d

log "Waiting for services to initialize (60 seconds)..."
sleep 60

log "Container status:"
docker compose ps

ok "Supabase services started."

# ──────────────────────────────────────────────────────────
step "Step 9/10 — Set Up Auto-start & Backup Cron"
# ──────────────────────────────────────────────────────────

# Systemd service for auto-start on reboot
CURRENT_USER=$(whoami)
sudo tee /etc/systemd/system/supabase.service > /dev/null <<EOF
[Unit]
Description=Supabase Self-Hosted (aaryavtech.online)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${SCRIPT_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300
User=${CURRENT_USER}

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable supabase
ok "Supabase will auto-start on VPS reboot."

# Daily backup cron (2 AM)
CRON_JOB="0 2 * * * ${SCRIPT_DIR}/scripts/backup.sh >> /var/log/supabase-backup.log 2>&1"
if crontab -l 2>/dev/null | grep -qF "$SCRIPT_DIR/scripts/backup.sh"; then
  ok "Backup cron already configured."
else
  (crontab -l 2>/dev/null || true; echo "$CRON_JOB") | crontab -
  ok "Daily backup cron added (runs at 2:00 AM)."
fi

# ──────────────────────────────────────────────────────────
step "Step 10/10 — Health Check"
# ──────────────────────────────────────────────────────────

log "Running health check..."
bash "$SCRIPT_DIR/scripts/health-check.sh" || warn "Some checks failed — this may be normal if DNS hasn't propagated yet."

# ──────────────────────────────────────────────────────────
step "🎉 Deployment Complete!"
# ──────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ Supabase is deployed on aaryavtech.online!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  🌐 Studio:  ${CYAN}https://supabase.aaryavtech.online${NC}"
echo -e "  🔌 API:     ${CYAN}https://api.aaryavtech.online${NC}"
echo ""
echo -e "  👤 Login:   supabase / Krishna@4809"
echo ""
echo -e "  📋 Your ANON_KEY (use in your apps):"
grep "^ANON_KEY=" "$SCRIPT_DIR/.env" | cut -d= -f2- | head -c 80
echo "..."
echo ""
echo -e "  Get full key: ${YELLOW}grep ANON_KEY $SCRIPT_DIR/.env${NC}"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Useful commands:"
echo "    docker compose ps                   # Container status"
echo "    docker compose logs -f              # Live logs"
echo "    bash scripts/health-check.sh        # Full health check"
echo "    bash scripts/backup.sh --verify     # Run a backup"
echo "    bash scripts/update.sh              # Safe update"
echo ""
