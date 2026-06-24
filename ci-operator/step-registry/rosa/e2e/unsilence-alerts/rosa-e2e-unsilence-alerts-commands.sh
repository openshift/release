#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

SILENCE_FILE="${SHARED_DIR}/silence-ids"

if [[ ! -f "$SILENCE_FILE" ]] || [[ ! -s "$SILENCE_FILE" ]]; then
  echo "No silences to expire (file missing or empty)"
  exit 0
fi

CLIENT_ID=$(cat /usr/local/rhobs-oidc/client_id)
CLIENT_SECRET=$(cat /usr/local/rhobs-oidc/client_secret)
ISSUER_URL=$(cat /usr/local/rhobs-oidc/oidc_issuer_url 2>/dev/null || echo "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token")

TOKEN=$(curl -sf -X POST "$ISSUER_URL" \
    -d "grant_type=client_credentials" \
    -d "client_id=$CLIENT_ID" \
    -d "client_secret=$CLIENT_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || {
  echo "WARNING: Failed to get RHOBS token, silences will expire naturally"
  exit 0
}

EXPIRED=0
TOTAL=0

while IFS='|' read -r CELL SILENCE_ID; do
  [[ -z "$CELL" || -z "$SILENCE_ID" ]] && continue
  TOTAL=$((TOTAL + 1))

  if curl -sf --max-time 10 \
    -X DELETE \
    -H "Authorization: Bearer $TOKEN" \
    "${CELL}/api/metrics/v1/hcp/am/api/v2/silence/${SILENCE_ID}" 2>/dev/null; then
    echo "  Expired: ${CELL} ${SILENCE_ID}"
    EXPIRED=$((EXPIRED + 1))
  else
    echo "  WARNING: Failed to expire ${SILENCE_ID} on ${CELL}"
  fi
done < "$SILENCE_FILE"

echo "Expired ${EXPIRED}/${TOTAL} silences"
