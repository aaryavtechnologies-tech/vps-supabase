#!/usr/bin/env bash
# ============================================================
# generate-secrets.sh
# Generates all required secrets for the Supabase .env file
# Run this ONCE before first deployment:
#   bash scripts/generate-secrets.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
ENV_EXAMPLE="$PROJECT_DIR/.env.example"

# ─── Check dependencies ────────────────────────────────────
for cmd in openssl python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not installed." >&2
    exit 1
  fi
done

echo "=============================================="
echo " Supabase Secret Generator"
echo " Project: aaryavtech.online"
echo "=============================================="

# ─── Safety check ──────────────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
  echo ""
  echo "WARNING: .env already exists at: $ENV_FILE"
  echo "If you regenerate, you MUST also update all running containers."
  echo "Changing JWT_SECRET invalidates all existing user sessions!"
  read -r -p "Overwrite existing .env? [y/N] " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted. No changes made."
    exit 0
  fi
fi

# ─── Generate raw secrets ──────────────────────────────────
echo ""
echo "Generating secrets..."

POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | head -c 40)
JWT_SECRET=$(openssl rand -base64 48 | tr -d '=+/')
SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '=+/')
REALTIME_DB_ENC_KEY=$(openssl rand -hex 8)          # exactly 16 chars
VAULT_ENC_KEY=$(openssl rand -hex 16)                # exactly 32 chars
PG_META_CRYPTO_KEY=$(openssl rand -base64 24 | tr -d '=+/')
LOGFLARE_PUBLIC_ACCESS_TOKEN=$(openssl rand -base64 24 | tr -d '=+/')
LOGFLARE_PRIVATE_ACCESS_TOKEN=$(openssl rand -base64 24 | tr -d '=+/')
S3_PROTOCOL_ACCESS_KEY_ID=$(openssl rand -hex 16)
S3_PROTOCOL_ACCESS_KEY_SECRET=$(openssl rand -hex 32)

# ─── Generate ANON_KEY and SERVICE_ROLE_KEY JWTs ──────────
echo "Generating JWT tokens (ANON_KEY, SERVICE_ROLE_KEY)..."

NOW=$(date +%s)
# 10 years from now
EXP=$((NOW + 315360000))

generate_jwt() {
  local role="$1"
  local secret="$JWT_SECRET"

  local header
  header=$(printf '{"alg":"HS256","typ":"JWT"}' | python3 -c "
import sys, json, base64
data = sys.stdin.read()
encoded = base64.urlsafe_b64encode(data.encode()).rstrip(b'=').decode()
print(encoded)
")

  local payload
  payload=$(python3 -c "
import json, base64, sys
data = json.dumps({'role': '${role}', 'iss': 'supabase', 'iat': ${NOW}, 'exp': ${EXP}})
encoded = base64.urlsafe_b64encode(data.encode()).rstrip(b'=').decode()
print(encoded)
")

  local signing_input="${header}.${payload}"

  local signature
  signature=$(printf '%s' "$signing_input" | openssl dgst -sha256 -hmac "$secret" -binary | python3 -c "
import sys, base64
data = sys.stdin.buffer.read()
print(base64.urlsafe_b64encode(data).rstrip(b'=').decode())
")

  echo "${signing_input}.${signature}"
}

ANON_KEY=$(generate_jwt "anon")
SERVICE_ROLE_KEY=$(generate_jwt "service_role")

# ─── Write .env file ───────────────────────────────────────
echo ""
echo "Writing .env file..."

cp "$ENV_EXAMPLE" "$ENV_FILE"

# Replace placeholder values with generated secrets
sed -i \
  -e "s|CHANGE_ME_use_generate-secrets.sh|GENERATED_PLACEHOLDER|g" \
  "$ENV_FILE"

# Now set each variable precisely
set_env() {
  local key="$1"
  local value="$2"
  # Escape special characters in value for sed
  local escaped_value
  escaped_value=$(printf '%s\n' "$value" | sed 's/[[\.*^$()+?{|]/\\&/g')
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${escaped_value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

set_env "POSTGRES_PASSWORD" "$POSTGRES_PASSWORD"
set_env "JWT_SECRET" "$JWT_SECRET"
set_env "ANON_KEY" "$ANON_KEY"
set_env "SERVICE_ROLE_KEY" "$SERVICE_ROLE_KEY"
set_env "SECRET_KEY_BASE" "$SECRET_KEY_BASE"
set_env "REALTIME_DB_ENC_KEY" "$REALTIME_DB_ENC_KEY"
set_env "VAULT_ENC_KEY" "$VAULT_ENC_KEY"
set_env "PG_META_CRYPTO_KEY" "$PG_META_CRYPTO_KEY"
set_env "LOGFLARE_PUBLIC_ACCESS_TOKEN" "$LOGFLARE_PUBLIC_ACCESS_TOKEN"
set_env "LOGFLARE_PRIVATE_ACCESS_TOKEN" "$LOGFLARE_PRIVATE_ACCESS_TOKEN"
set_env "S3_PROTOCOL_ACCESS_KEY_ID" "$S3_PROTOCOL_ACCESS_KEY_ID"
set_env "S3_PROTOCOL_ACCESS_KEY_SECRET" "$S3_PROTOCOL_ACCESS_KEY_SECRET"
set_env "DASHBOARD_PASSWORD" "Krishna@4809"

# Secure file permissions (owner read/write only)
chmod 600 "$ENV_FILE"

echo ""
echo "=============================================="
echo " ✅ .env generated successfully!"
echo "=============================================="
echo ""
echo " ANON_KEY (use in your frontend app):"
echo " $ANON_KEY"
echo ""
echo " SERVICE_ROLE_KEY (KEEP SECRET — server only):"
echo " $SERVICE_ROLE_KEY"
echo ""
echo " Dashboard password: Krishna@4809"
echo ""
echo " IMPORTANT:"
echo "  1. Edit .env and fill in your SMTP password:"
echo "     SMTP_PASS=your_hostinger_email_password"
echo "  2. Never commit .env to Git!"
echo "  3. Store a copy of this output securely."
echo "=============================================="
