#!/bin/sh
# ============================================================
# Envoy docker-entrypoint.sh
# Processes lds.template.yaml → lds.yaml with runtime values
# ============================================================
set -e

# Generate SHA1 base64 hash for Envoy basic auth user list
PASSWORD_HASH=$(printf '%s' "${DASHBOARD_PASSWORD}" | openssl sha1 -binary | openssl base64)
DASHBOARD_BASIC_AUTH="${DASHBOARD_USERNAME}:{SHA}${PASSWORD_HASH}"

# Generate base64-encoded JWT secret for JWT filter
JWT_BASE64_SECRET=$(printf '%s' "${ANON_KEY}" | cut -d. -f2 | base64 -d 2>/dev/null | python3 -c "
import sys, json, base64
payload = json.load(sys.stdin)
" 2>/dev/null || echo "${JWT_SECRET}" | openssl base64 -A)

echo "Generating Envoy LDS configuration..."

# Process the lds.template.yaml with environment variables using sed
# Using | as delimiter since JWT tokens contain /
sed -e "s|\${ANON_KEY}|${ANON_KEY}|g" \
    -e "s|\${ANON_KEY_ASYMMETRIC}|${ANON_KEY_ASYMMETRIC:-}|g" \
    -e "s|\${SERVICE_ROLE_KEY}|${SERVICE_ROLE_KEY}|g" \
    -e "s|\${SERVICE_ROLE_KEY_ASYMMETRIC}|${SERVICE_ROLE_KEY_ASYMMETRIC:-}|g" \
    -e "s|\${SUPABASE_PUBLISHABLE_KEY}|${SUPABASE_PUBLISHABLE_KEY:-}|g" \
    -e "s|\${SUPABASE_SECRET_KEY}|${SUPABASE_SECRET_KEY:-}|g" \
    -e "s|\${DASHBOARD_USERNAME}|${DASHBOARD_USERNAME}|g" \
    -e "s|\${DASHBOARD_PASSWORD}|${DASHBOARD_PASSWORD}|g" \
    -e "s|\${DASHBOARD_BASIC_AUTH}|${DASHBOARD_BASIC_AUTH}|g" \
    -e "s|\${JWT_BASE64_SECRET}|${JWT_BASE64_SECRET}|g" \
    /etc/envoy/lds.template.yaml > /etc/envoy/lds.yaml

echo "Envoy LDS configuration generated at /etc/envoy/lds.yaml"
echo "Starting Envoy..."

exec envoy -c /etc/envoy/envoy.yaml "$@"
