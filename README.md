# 🚀 Self-Hosted Supabase on VPS — aaryavtech.online

Production-ready Supabase deployment using **Docker Compose** + **Caddy** reverse proxy with automatic HTTPS.

> **Architecture**: This uses the **current official** Supabase self-hosted stack with **Envoy** as the API gateway (not Kong — Envoy replaced Kong in 2025/2026).

---

## Table of Contents

1. [VPS Requirements](#1-vps-requirements)
2. [Domain & DNS Setup](#2-domain--dns-setup)
3. [Required Ports](#3-required-ports)
4. [Docker Installation](#4-docker-installation)
5. [Supabase Installation](#5-supabase-installation)
6. [Environment Configuration](#6-environment-configuration)
7. [Reverse Proxy (Caddy) Configuration](#7-reverse-proxy-caddy-configuration)
8. [HTTPS Setup](#8-https-setup)
9. [Starting Supabase](#9-starting-supabase)
10. [Opening Studio](#10-opening-studio)
11. [Connecting an Application](#11-connecting-an-application)
12. [Realtime Testing](#12-realtime-testing)
13. [Backup](#13-backup)
14. [Restore](#14-restore)
15. [Updating](#15-updating)
16. [Troubleshooting](#16-troubleshooting)
17. [Security Checklist](#17-security-checklist)

---

## 1. VPS Requirements

| Resource | Minimum | This VPS |
|---|---|---|
| CPU | 2 cores | 4 cores ✅ |
| RAM | 4 GB | 8 GB ✅ |
| Storage | 50 GB | 150 GB ✅ |
| OS | Ubuntu 22.04+ | Ubuntu 22.04/24.04 ✅ |
| Public IPv4 | Required | ✅ |
| Domain | Required | aaryavtech.online ✅ |

### Pre-flight checks (run on VPS before starting)

```bash
# Check Ubuntu version
lsb_release -a

# Check available RAM
free -h

# Check available disk
df -h /

# Check ports 80/443 availability
sudo ss -tlnp | grep -E ':80|:443'

# Check if Docker is installed
docker --version
docker compose version

# Check if another web server is running
sudo systemctl status nginx apache2 caddy 2>/dev/null | grep "Active:"

# Check DNS resolution (replace with your VPS IP first!)
dig supabase.aaryavtech.online +short
dig api.aaryavtech.online +short
```

> ⚠️ If ports 80/443 are in use by Nginx/Apache, stop them before proceeding:
> `sudo systemctl stop nginx && sudo systemctl disable nginx`

---

## 2. Domain & DNS Setup

Create these **A records** at your DNS provider (Hostinger, Cloudflare, etc.):

| Type | Name | Value | TTL |
|---|---|---|---|
| A | `supabase` | `<YOUR_VPS_IPV4>` | 300 |
| A | `api` | `<YOUR_VPS_IPV4>` | 300 |

**Full domain → subdomain mapping:**

| URL | What it does |
|---|---|
| `https://supabase.aaryavtech.online` | Supabase Studio (web dashboard) |
| `https://api.aaryavtech.online` | Supabase API (all endpoints) |
| `https://api.aaryavtech.online/rest/v1/` | PostgREST auto-generated REST API |
| `https://api.aaryavtech.online/auth/v1/` | GoTrue authentication |
| `https://api.aaryavtech.online/storage/v1/` | Supabase Storage |
| `https://api.aaryavtech.online/realtime/v1/` | WebSocket Realtime |
| `https://api.aaryavtech.online/functions/v1/` | Edge Functions (Deno) |

> **PostgreSQL is NEVER given a public DNS record.** It is only accessible inside Docker's internal network.

### Wait for DNS propagation

```bash
# Check that DNS has propagated (may take 0–48 hours)
watch -n 30 "dig supabase.aaryavtech.online +short && dig api.aaryavtech.online +short"
```

---

## 3. Required Ports

| Port | Protocol | Direction | Purpose |
|---|---|---|---|
| 22 | TCP | Inbound | SSH (consider changing to non-standard) |
| 80 | TCP | Inbound | HTTP (Caddy redirects to HTTPS) |
| 443 | TCP | Inbound | HTTPS (Caddy + Let's Encrypt) |

**Ports that must NOT be publicly exposed:**

| Port | Service | Why |
|---|---|---|
| 5432 | PostgreSQL | Contains all data — internal only |
| 6543 | Supavisor pooler | Internal pooling only |
| 8000 | Envoy gateway | Caddy proxies this internally |
| 9999 | GoTrue auth | Internal service |
| 3000 | PostgREST | Internal service |
| 4000 | Realtime | Internal service |
| 5000 | Storage | Internal service |
| 9000 | Edge Functions | Internal service |
| 8080 | postgres-meta | Internal service |

---

## 4. Docker Installation

```bash
# SSH into your VPS
ssh user@YOUR_VPS_IP

# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker (official method)
curl -fsSL https://get.docker.com | sudo bash

# Add your user to docker group (so you don't need sudo)
sudo usermod -aG docker $USER

# Apply group membership (or log out and back in)
newgrp docker

# Verify
docker --version
docker compose version
```

### UFW Firewall setup

```bash
# Enable UFW firewall
sudo ufw enable

# Allow SSH (CRITICAL — do this before enabling UFW!)
sudo ufw allow 22/tcp

# Allow HTTP and HTTPS
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Block all other inbound (PostgreSQL, Envoy, etc. are already on localhost)
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Verify
sudo ufw status verbose
```

---

## 5. Supabase Installation

```bash
# Create the project directory
sudo mkdir -p /opt/supabase
sudo chown $USER:$USER /opt/supabase

# Copy project files to VPS (run from your LOCAL machine)
# Option A: SCP
scp -r . user@YOUR_VPS_IP:/opt/supabase/

# Option B: Git clone (if you pushed to a private repo)
# git clone https://github.com/YOUR_ORG/supabase-deploy.git /opt/supabase

# On VPS: Go to project directory
cd /opt/supabase

# Create backup directory
mkdir -p backups

# Create required volume directories
mkdir -p volumes/snippets
mkdir -p volumes/functions

# Make scripts executable
chmod +x scripts/*.sh
```

---

## 6. Environment Configuration

```bash
cd /opt/supabase

# Step 1: Generate all secrets automatically
bash scripts/generate-secrets.sh

# This creates .env with:
#   - Random POSTGRES_PASSWORD
#   - Random JWT_SECRET
#   - Generated ANON_KEY and SERVICE_ROLE_KEY (JWT tokens)
#   - All encryption keys

# Step 2: Set your Hostinger SMTP password
# (Open .env and find SMTP_PASS)
nano .env
# Change: SMTP_PASS=your_hostinger_email_password
# Save: Ctrl+O, Enter, Ctrl+X

# Step 3: Verify .env permissions (should be 600)
ls -la .env
# Should show: -rw------- (owner read/write only)
# If not: chmod 600 .env

# Step 4: Save your ANON_KEY — you'll need it for apps
grep ANON_KEY .env
```

### Hostinger SMTP Configuration

In Hostinger hPanel:
1. Go to **Email → Email Accounts**
2. Create `noreply@aaryavtech.online` (or note existing credentials)
3. Use these SMTP settings in `.env`:
   ```
   SMTP_HOST=smtp.hostinger.com
   SMTP_PORT=587
   SMTP_USER=noreply@aaryavtech.online
   SMTP_PASS=your_email_password_here
   SMTP_SENDER_NAME=Supabase - aaryavtech
   ```
4. If SMTP doesn't work initially, keep `ENABLE_EMAIL_AUTOCONFIRM=true` and set it to `false` once SMTP is verified

### How to Rotate Secrets Safely

> ⚠️ **Warning**: Rotating `JWT_SECRET` invalidates ALL existing user sessions!

```bash
# 1. Create backup before rotating
bash scripts/backup.sh --verify

# 2. Stop all services
docker compose down

# 3. Generate new secrets
bash scripts/generate-secrets.sh
# This overwrites .env with new values

# 4. Update your apps with the new ANON_KEY

# 5. Restart
docker compose up -d

# 6. Verify all users can log in again
# (All sessions are invalidated — users must log in again)
```

---

## 7. Reverse Proxy (Caddy) Configuration

### Install Caddy

```bash
# Install Caddy (official method)
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy

# Verify
caddy version
```

### Configure Caddy

```bash
# Copy Caddyfile to Caddy config location
sudo cp /opt/supabase/Caddyfile /etc/caddy/Caddyfile

# Create log directory
sudo mkdir -p /var/log/caddy
sudo chown caddy:caddy /var/log/caddy

# Test Caddy configuration
sudo caddy validate --config /etc/caddy/Caddyfile

# Apply configuration
sudo caddy reload --config /etc/caddy/Caddyfile
```

---

## 8. HTTPS Setup

Caddy **automatically** obtains and renews Let's Encrypt certificates.

### Requirements for automatic HTTPS

1. DNS A records must point to this VPS (verified in Step 2)
2. Port 80 and 443 must be open (verified in Step 3)
3. Caddy must be running

### Start Caddy as a system service

```bash
# Enable Caddy to start on boot
sudo systemctl enable caddy
sudo systemctl start caddy

# Check Caddy status
sudo systemctl status caddy

# Check Caddy logs
sudo journalctl -u caddy -f
```

### Verify HTTPS is working

```bash
# After Caddy starts and DNS is resolved:
curl -I https://api.aaryavtech.online/health
curl -I https://supabase.aaryavtech.online

# Check TLS certificate details
echo | openssl s_client -connect api.aaryavtech.online:443 -servername api.aaryavtech.online 2>/dev/null | openssl x509 -noout -dates
```

> **Using Let's Encrypt staging (for testing):**
> Uncomment the `acme_ca` line in `Caddyfile` to avoid rate limits during testing.
> Remove it (use production) once everything works.

---

## 9. Starting Supabase

```bash
cd /opt/supabase

# Start all Supabase services
docker compose up -d

# Watch startup (takes 1-3 minutes on first run)
docker compose ps
docker compose logs -f

# Wait until all services show "healthy" or "Up"
watch -n 5 "docker compose ps"
```

### Service startup order

The stack starts in this order automatically (via `depends_on`):
1. `db` (PostgreSQL) — must be healthy first
2. `analytics` (Logflare) — needs DB
3. `auth`, `rest`, `storage`, `realtime`, `functions`, `meta`, `supavisor`
4. `studio` — needs `meta`
5. `api-gw` (Envoy) — needs Studio to be healthy
6. `vector` — needs analytics

### Set up daily backups (cron)

```bash
# Open crontab
crontab -e

# Add this line (daily backup at 2 AM):
0 2 * * * /opt/supabase/scripts/backup.sh >> /var/log/supabase-backup.log 2>&1
```

### Autostart Supabase on VPS reboot

```bash
# Create systemd service file
sudo tee /etc/systemd/system/supabase.service > /dev/null <<'EOF'
[Unit]
Description=Supabase Self-Hosted
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/supabase
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300
User=YOUR_USERNAME

[Install]
WantedBy=multi-user.target
EOF

# Replace YOUR_USERNAME with actual user
sudo sed -i "s/YOUR_USERNAME/$USER/" /etc/systemd/system/supabase.service

sudo systemctl daemon-reload
sudo systemctl enable supabase
```

---

## 10. Opening Studio

1. Open your browser: **`https://supabase.aaryavtech.online`**
2. You will be prompted for credentials:
   - **Username**: `supabase` (from `DASHBOARD_USERNAME` in `.env`)
   - **Password**: `Krishna@4809` (from `DASHBOARD_PASSWORD` in `.env`)
3. You should see the Supabase Studio dashboard

### What you can manage in Studio

| Feature | Location in Studio |
|---|---|
| Tables & data | Table Editor |
| SQL queries | SQL Editor |
| Database schema | Database → Tables |
| Row Level Security | Database → Policies |
| Auth users | Authentication → Users |
| Auth settings | Authentication → Providers |
| Storage buckets | Storage |
| Realtime subscriptions | Database → Replication |
| Database functions | Database → Functions |
| Edge Functions | Edge Functions |
| Logs | Logs |

> **Note**: Some Supabase Cloud features are NOT available in self-hosted:
> - Branching
> - PITR (Point-in-time recovery)
> - Multi-organization management
> - Managed backups (you manage these yourself with `backup.sh`)

---

## 11. Connecting an Application

### Install Supabase JS client

```bash
npm install @supabase/supabase-js
```

### Basic configuration

```typescript
import { createClient } from '@supabase/supabase-js'

// Self-hosted configuration for aaryavtech.online
const supabase = createClient(
  'https://api.aaryavtech.online',  // SUPABASE_PUBLIC_URL
  'YOUR_ANON_KEY'                    // from .env ANON_KEY — safe for frontend!
)
```

> ⚠️ **NEVER put `SERVICE_ROLE_KEY` in frontend/client code.**
> Service role key bypasses Row Level Security and exposes your entire database.

### Example: Authentication

```typescript
// Sign up
const { data, error } = await supabase.auth.signUp({
  email: 'user@example.com',
  password: 'secure-password'
})

// Sign in
const { data: { session } } = await supabase.auth.signInWithPassword({
  email: 'user@example.com',
  password: 'secure-password'
})

// Get current user
const { data: { user } } = await supabase.auth.getUser()
```

### Example: Database query

```typescript
// Fetch all records (respects RLS automatically)
const { data, error } = await supabase
  .from('drivers')
  .select('*')
  .eq('status', 'available')

// Insert a record
const { data, error } = await supabase
  .from('drivers')
  .insert({ name: 'Chirag', status: 'available', lat: 12.9, lng: 77.6 })
  .select()
  .single()
```

### Full example: see [`app-example/supabase-client.ts`](./app-example/supabase-client.ts)

---

## 12. Realtime Testing

### Setup: Enable Realtime for a table

1. Open **Studio** → **Database → Replication**
2. Click `supabase_realtime` publication
3. Click **Add Table** → select your table → Save

Or using SQL:
```sql
-- Enable realtime for a specific table
ALTER PUBLICATION supabase_realtime ADD TABLE public.my_table;
```

### Quick test using the included HTML page

1. Open `app-example/realtime-test.html` in a text editor
2. Replace `YOUR_ANON_KEY` with your `ANON_KEY` from `.env`
3. Create the test table in Studio SQL editor:
   ```sql
   CREATE TABLE public.realtime_test (
     id SERIAL PRIMARY KEY,
     message TEXT NOT NULL,
     created_by TEXT DEFAULT 'browser',
     created_at TIMESTAMPTZ DEFAULT now()
   );

   ALTER TABLE public.realtime_test ENABLE ROW LEVEL SECURITY;
   CREATE POLICY "Allow all for test" ON public.realtime_test FOR ALL USING (true);

   -- Enable realtime
   ALTER PUBLICATION supabase_realtime ADD TABLE public.realtime_test;
   ```
4. Open `realtime-test.html` in **two browser tabs**
5. Click **Insert Row** in Tab A
6. Watch the row appear instantly in Tab B without refreshing!

### Realtime use cases in your apps

```typescript
// Ride tracking — subscribe to driver location updates
supabase
  .channel('driver-locations')
  .on('postgres_changes', {
    event: 'UPDATE',
    schema: 'public',
    table: 'drivers'
  }, (payload) => {
    updateMapMarker(payload.new)   // Update map in real time
  })
  .subscribe()

// Admin dashboard — subscribe to new orders
supabase
  .channel('new-orders')
  .on('postgres_changes', {
    event: 'INSERT',
    schema: 'public',
    table: 'orders'
  }, (payload) => {
    showNotification(`New order #${payload.new.id}`)
  })
  .subscribe()
```

---

## 13. Backup

### Manual backup

```bash
cd /opt/supabase

# Run backup
bash scripts/backup.sh

# Run backup and verify integrity
bash scripts/backup.sh --verify

# List existing backups
ls -lh backups/
```

### Automatic daily backup (cron)

```bash
# View current crontab
crontab -l

# Edit crontab to add daily backup at 2 AM
crontab -e
# Add: 0 2 * * * /opt/supabase/scripts/backup.sh >> /var/log/supabase-backup.log 2>&1
```

### Backup retention

Default: **7 days** of backups. Configure in `.env`:
```bash
BACKUP_RETENTION_DAYS=14   # Keep 14 days of backups
```

### Disk space for backups

- Reserve **at least 3x your database size** for local backups
- With 7-day retention: estimate 7x your average daily backup size
- Monitor: `du -sh /opt/supabase/backups/`
- Current DB size: `docker compose exec db psql -U postgres -c "SELECT pg_size_pretty(pg_database_size('postgres'));"`

### Off-server backup (recommended for production)

Edit `scripts/backup.sh` and uncomment one of:

**Option A — Rclone (most flexible — supports S3, B2, Google Drive):**
```bash
# Install rclone
curl https://rclone.org/install.sh | sudo bash
# Configure (interactive)
rclone config
# Uncomment rclone section in backup.sh
```

**Option B — AWS S3:**
```bash
sudo apt install awscli
aws configure
# Uncomment S3 section in backup.sh
```

---

## 14. Restore

> ⚠️ **The restore script creates an automatic safety backup before restoring.**

```bash
cd /opt/supabase

# Option A: Restore latest backup
bash scripts/restore.sh

# Option B: Restore specific backup file
bash scripts/restore.sh backups/supabase_2026-08-11_02-00-00.dump

# After restore, run health check
bash scripts/health-check.sh
```

### What the restore script does

1. Creates a **safety backup** of the current database state
2. Asks for **explicit confirmation** before proceeding
3. Stops all services that use the database
4. Drops and recreates the PostgreSQL database
5. Restores from the backup file
6. Restarts all services
7. Confirms success

### Manual restore (if script fails)

```bash
# Stop dependent services
docker compose stop auth rest realtime storage functions analytics supavisor studio api-gw

# Restore using pg_restore
cat backups/supabase_2026-08-11_02-00-00.dump | \
  docker compose exec -T db pg_restore \
    --username=postgres \
    --dbname=postgres \
    --no-owner \
    --no-acl

# Restart
docker compose up -d
```

---

## 15. Updating

> Use `scripts/update.sh` for safe updates — it backs up before updating.

```bash
cd /opt/supabase

# Safe update (backup + pull + restart + verify)
bash scripts/update.sh
```

### Updating image versions

1. Check Supabase releases: https://github.com/supabase/supabase/releases
2. Find the latest `docker/` directory changes
3. Update image tags in `docker-compose.yml`:
   ```yaml
   # Example: update Studio
   image: supabase/studio:2026.09.01-sha-abc1234   # ← new tag
   ```
4. Run: `bash scripts/update.sh`

> **Why not use `latest` tags?**
> `latest` tags can introduce breaking database migrations or config changes without warning.
> Always use pinned SHA tags for production stability.

---

## 16. Troubleshooting

### Run the health check first

```bash
bash scripts/health-check.sh
```

---

### Container won't start

```bash
# Check container status
docker compose ps

# View logs for a specific service
docker compose logs db
docker compose logs auth
docker compose logs api-gw

# Follow logs in real time
docker compose logs -f studio

# Restart a single service
docker compose restart auth
```

---

### Studio shows blank page or 502 error

```bash
# Check Envoy is running
docker compose ps api-gw

# Check Studio is healthy
docker compose logs studio --tail=50

# Restart the gateway + studio
docker compose restart studio api-gw
```

---

### Auth email not working

1. Check SMTP settings in `.env`:
   ```bash
   grep SMTP .env
   ```
2. Test SMTP from VPS:
   ```bash
   apt install swaks
   swaks --auth --server smtp.hostinger.com --port 587 \
     --auth-user noreply@aaryavtech.online \
     --auth-password YOUR_PASS \
     --to test@example.com \
     --h-Subject "SMTP Test" \
     --body "Testing Hostinger SMTP"
   ```
3. If SMTP fails, set `ENABLE_EMAIL_AUTOCONFIRM=true` temporarily

---

### Realtime not working

```bash
# Check realtime service
docker compose logs realtime --tail=50

# Verify table is in the realtime publication
docker compose exec db psql -U postgres -c \
  "SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname = 'supabase_realtime';"

# Check WebSocket connectivity
curl -I https://api.aaryavtech.online/realtime/v1/websocket
```

---

### HTTPS certificate issues

```bash
# Check Caddy status
sudo systemctl status caddy
sudo journalctl -u caddy -f

# Check that DNS points to VPS (replace with actual IP)
dig supabase.aaryavtech.online +short   # Should return your VPS IP
dig api.aaryavtech.online +short

# Force certificate renewal
sudo caddy reload --config /etc/caddy/Caddyfile

# Check certificate
echo | openssl s_client -connect api.aaryavtech.online:443 2>/dev/null | openssl x509 -noout -dates
```

---

### PostgreSQL out of connections

```bash
# Check current connections
docker compose exec db psql -U postgres -c \
  "SELECT count(*), state FROM pg_stat_activity GROUP BY state;"

# Check max connections setting
docker compose exec db psql -U postgres -c "SHOW max_connections;"

# Restart connection pooler (Supavisor)
docker compose restart supavisor
```

---

### Disk space full

```bash
# Check overall disk usage
df -h /

# Find large directories
du -sh /opt/supabase/* /var/lib/docker/*

# Clean up old Docker images
docker image prune -f

# Remove old backups manually
ls -lh /opt/supabase/backups/
# rm /opt/supabase/backups/supabase_OLD_DATE.dump
```

---

### Monitoring commands reference

```bash
# System
htop                                     # Interactive CPU/RAM monitor
free -h                                  # RAM usage
df -h                                    # Disk usage
iostat -x 1 5                           # Disk I/O

# Docker
docker compose ps                        # Container status
docker compose logs -f                   # All logs (stream)
docker compose logs -f auth              # Specific service logs
docker stats                             # Live CPU/RAM per container

# PostgreSQL
docker compose exec db psql -U postgres  # Open psql console
docker compose exec db psql -U postgres -c "SELECT now();"   # Quick test
docker compose exec db psql -U postgres -c "SELECT count(*) FROM auth.users;"  # User count

# Check all services
bash scripts/health-check.sh
```

---

## 17. Security Checklist

### Before going live, verify ALL of these:

- [ ] **`.env` file**: `chmod 600 .env` — readable only by owner
- [ ] **`.env` not in Git**: `git status` should not show `.env`
- [ ] **Firewall enabled**: `sudo ufw status` shows only 22, 80, 443 allowed
- [ ] **PostgreSQL not public**: `sudo ss -tlnp | grep 5432` — should only show `127.0.0.1:5432`
- [ ] **Strong passwords**: `POSTGRES_PASSWORD`, `JWT_SECRET` generated by `generate-secrets.sh`
- [ ] **Dashboard password**: Changed from default (`Krishna@4809` — consider changing for production)
- [ ] **HTTPS working**: `https://api.aaryavtech.online` returns valid TLS cert
- [ ] **HTTP redirects**: `http://api.aaryavtech.online` redirects to HTTPS
- [ ] **Backups running**: Check `crontab -l` for daily backup cron
- [ ] **Backup tested**: Run `backup.sh --verify` at least once
- [ ] **Docker socket**: Not exposed externally (`docker info` works only locally)
- [ ] **Service ports**: No Supabase services listen on 0.0.0.0 except via Caddy
- [ ] **RLS enabled**: All public tables have Row Level Security enabled
- [ ] **SERVICE_ROLE_KEY**: Never in frontend code (only backend/server-side)
- [ ] **SSH hardened**: Disable password auth, use SSH keys only
- [ ] **Auto-updates**: Consider `unattended-upgrades` for security patches

### Optional hardening

```bash
# Disable SSH password authentication (use SSH keys only)
sudo nano /etc/ssh/sshd_config
# Set: PasswordAuthentication no
sudo systemctl restart sshd

# Install fail2ban (blocks repeated failed logins)
sudo apt install fail2ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# Enable automatic security updates
sudo apt install unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

---

## Project Structure

```
/opt/supabase/
├── docker-compose.yml          # Official Supabase stack (Envoy + all services)
├── .env                        # Your secrets (NEVER in Git!)
├── .env.example                # Template (safe to commit)
├── .gitignore                  # Excludes .env, backups, etc.
├── Caddyfile                   # Reverse proxy + HTTPS config
├── README.md                   # This file
│
├── scripts/
│   ├── generate-secrets.sh     # Generate all secrets → .env
│   ├── backup.sh               # Daily PostgreSQL backup
│   ├── restore.sh              # Restore from backup
│   ├── health-check.sh         # Check all services
│   └── update.sh               # Safe update procedure
│
├── backups/                    # PostgreSQL backup files (gitignored)
│
├── volumes/
│   ├── api/envoy/              # Envoy API gateway config
│   │   ├── envoy.yaml          # Base Envoy config
│   │   ├── cds.yaml            # Cluster definitions (upstream services)
│   │   ├── lds.template.yaml   # Listener/routing template
│   │   └── docker-entrypoint.sh # Processes template → lds.yaml
│   ├── db/                     # PostgreSQL init SQL files
│   │   ├── webhooks.sql
│   │   ├── roles.sql
│   │   ├── jwt.sql
│   │   ├── logs.sql
│   │   └── pooler.sql
│   ├── functions/              # Edge Function source files
│   ├── snippets/               # Studio SQL snippets
│   └── logs/
│       └── vector.yml          # Log aggregation config
│
└── app-example/
    ├── supabase-client.ts      # TypeScript client with auth/DB/realtime
    └── realtime-test.html      # Browser test for realtime functionality
```

---

## Self-hosted vs Supabase Cloud — Key Differences

| Feature | Self-hosted | Supabase Cloud |
|---|---|---|
| Data location | Your VPS | Supabase's servers |
| Cost | VPS cost only | Free tier + paid plans |
| Projects | Single project | Multiple projects |
| Branching | ❌ Not available | ✅ Available |
| PITR (backups) | Manual (`backup.sh`) | Managed by Supabase |
| Scaling | Manual (upgrade VPS) | Automatic |
| Studio | ✅ Full access | ✅ Full access |
| Auth / GoTrue | ✅ Full | ✅ Full |
| PostgREST | ✅ Full | ✅ Full |
| Realtime | ✅ Full | ✅ Full |
| Storage | ✅ Full | ✅ Full |
| Edge Functions | ✅ Full (Deno) | ✅ Full (Deno) |
| Logs | Via Logflare (self) | Managed |
| Support | Community / GitHub | Official support |

---

*Generated for aaryavtech.online — Self-Hosted Supabase Production Deployment*
