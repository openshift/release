#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

RHOBS_ENV="${RHOBS_ENV:-production}"
SILENCE_MATCHER_NAME="${SILENCE_MATCHER_NAME:-_id}"
SILENCE_MATCHER_VALUE="${SILENCE_MATCHER_VALUE:-cs-ci-.*}"
SILENCE_DURATION_HOURS="${SILENCE_DURATION_HOURS:-6}"

case "$RHOBS_ENV" in
  production)
    CELLS=(
      "https://us-east-1-0.rhobs.api.openshift.com"
      "https://us-east-1-1.rhobs.api.openshift.com"
      "https://us-east-1-2.rhobs.api.openshift.com"
      "https://us-west-2-0.rhobs.api.openshift.com"
      "https://eu-west-1-0.rhobs.api.openshift.com"
      "https://eu-central-1-0.rhobs.api.openshift.com"
      "https://sa-east-1-0.rhobs.api.openshift.com"
      "https://ap-northeast-1-0.rhobs.api.openshift.com"
      "https://ap-southeast-2-0.rhobs.api.openshift.com"
    )
    ;;
  staging)
    CELLS=(
      "https://us-east-1-0.rhobs.api.stage.openshift.com"
      "https://us-west-2-0.rhobs.api.stage.openshift.com"
    )
    ;;
  *)
    echo "ERROR: RHOBS_ENV must be production or staging"
    exit 1
    ;;
esac

CLIENT_ID=$(cat /usr/local/rhobs-oidc/client_id)
CLIENT_SECRET=$(cat /usr/local/rhobs-oidc/client_secret)
ISSUER_URL=$(cat /usr/local/rhobs-oidc/oidc_issuer_url 2>/dev/null || echo "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token")

TOKEN=$(curl -sf -X POST "$ISSUER_URL" \
    -d "grant_type=client_credentials" \
    -d "client_id=$CLIENT_ID" \
    -d "client_secret=$CLIENT_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || {
  echo "WARNING: Failed to get RHOBS token, skipping silence creation"
  exit 0
}

START=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
END=$(python3 -c "
from datetime import datetime, timedelta, timezone
end = datetime.now(timezone.utc) + timedelta(hours=$SILENCE_DURATION_HOURS)
print(end.strftime('%Y-%m-%dT%H:%M:%S.000Z'))
")

JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/"
if [[ -n "${PULL_NUMBER:-}" ]]; then
  JOB_URL="${JOB_URL}pr-logs/pull/${REPO_OWNER:-}_${REPO_NAME:-}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
  JOB_URL="${JOB_URL}logs/${JOB_NAME:-unknown}/${BUILD_ID:-0}"
fi

COMMENT="ROSAENG-60057: Silencing ${SILENCE_MATCHER_NAME}=~${SILENCE_MATCHER_VALUE} for FVT job ${JOB_URL}"

echo "Creating silences on ${#CELLS[@]} ${RHOBS_ENV} RHOBS cells"
echo "  Matcher: ${SILENCE_MATCHER_NAME} =~ ${SILENCE_MATCHER_VALUE}"
echo "  Duration: ${SILENCE_DURATION_HOURS}h (${START} -> ${END})"

: > "${SHARED_DIR}/silence-ids"

CREATED=0
for CELL in "${CELLS[@]}"; do
  SILENCE_URL="${CELL}/api/metrics/v1/hcp/am/api/v2/silences"

  RESULT=$(curl -sf --max-time 10 \
    -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "$SILENCE_URL" \
    -d "{
      \"matchers\": [{
        \"name\": \"${SILENCE_MATCHER_NAME}\",
        \"value\": \"${SILENCE_MATCHER_VALUE}\",
        \"isRegex\": true,
        \"isEqual\": true
      }],
      \"startsAt\": \"${START}\",
      \"endsAt\": \"${END}\",
      \"createdBy\": \"rosa-ci-prow\",
      \"comment\": \"${COMMENT}\"
    }" 2>/dev/null) || {
    echo "  WARNING: Failed to create silence on ${CELL}"
    continue
  }

  SILENCE_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('silenceID',''))" 2>/dev/null)

  if [[ -n "$SILENCE_ID" ]]; then
    echo "  ${CELL}: ${SILENCE_ID}"
    echo "${CELL}|${SILENCE_ID}" >> "${SHARED_DIR}/silence-ids"
    CREATED=$((CREATED + 1))
  else
    echo "  WARNING: No silence ID returned from ${CELL}"
  fi
done

echo "Created ${CREATED}/${#CELLS[@]} silences"
