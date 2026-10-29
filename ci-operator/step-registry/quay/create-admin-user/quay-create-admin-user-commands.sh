#!/bin/bash
set -euo pipefail

ADMIN_USERNAME="admin"
ADMIN_PASSWORD="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 24)"
ADMIN_EMAIL="admin@localhost.local"

echo "Getting Quay registry endpoint..." >&2
registryEndpoint="$(oc -n quay get quayregistry quay -o jsonpath='{.status.registryEndpoint}')"

# Disable tracing due to password handling
echo "Creating admin user via initialization API..." >&2
response="$(curl -sk --retry 30 --retry-delay 10 --retry-all-errors \
  -X POST "$registryEndpoint/api/v1/user/initialize" \
  --header 'Content-Type: application/json' \
  --data "{\"username\": \"${ADMIN_USERNAME}\", \"password\": \"${ADMIN_PASSWORD}\", \"email\": \"${ADMIN_EMAIL}\", \"access_token\": false}")"

if echo "$response" | grep -q '"username"'; then
  echo "Admin user created successfully" >&2
else
  echo "Failed to create admin user: $response" >&2
  exit 1
fi

# Write credentials to SHARED_DIR for downstream steps
echo "$ADMIN_USERNAME" > "${SHARED_DIR}/quay-admin-username"
echo "$ADMIN_PASSWORD" > "${SHARED_DIR}/quay-admin-password"
