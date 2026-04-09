#!/bin/bash
# Post a daily ROSA CI status summary to Slack via chat.postMessage API.
set -euo pipefail

readonly GCS_BASE="https://storage.googleapis.com/test-platform-results"
readonly PROW_BASE="https://prow.ci.openshift.org/view/gs/test-platform-results"
SLACK_CHANNEL="${SLACK_CHANNEL:-C0ADGRNAT8U}"

# Resolve bot token
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
if [[ -z "${SLACK_BOT_TOKEN}" ]]; then
  for f in "${CLUSTER_PROFILE_DIR:-}/slack-bot-token" "/tmp/secrets/slack-bot-token"; do
    if [[ -f "${f}" ]]; then
      SLACK_BOT_TOKEN=$(cat "${f}")
      break
    fi
  done
fi
if [[ -z "${SLACK_BOT_TOKEN}" ]]; then
  echo "ERROR: No Slack bot token found" >&2; exit 1
fi

JOBS=(
  "rosa-e2e nightly|periodic-ci-openshift-online-rosa-e2e-main-rosa-hcp-e2e-nightly"
  "OCM FVT periodic|periodic-ci-openshift-online-rosa-e2e-main-ocm-fvt-periodic-cs-rosa-hcp-ad-staging-main"
  "HCP conformance 4.19|periodic-ci-openshift-release-main-nightly-4.19-e2e-rosa-hcp-ovn"
  "HCP conformance 4.20|periodic-ci-openshift-release-main-nightly-4.20-e2e-rosa-hcp-ovn"
  "HCP conformance 4.21|periodic-ci-openshift-release-main-nightly-4.21-e2e-rosa-hcp-ovn"
  "Classic STS 4.19|periodic-ci-openshift-release-main-nightly-4.19-e2e-rosa-sts-ovn"
  "Classic STS 4.20|periodic-ci-openshift-release-main-nightly-4.20-e2e-rosa-sts-ovn"
  "Classic STS 4.21|periodic-ci-openshift-release-main-nightly-4.21-e2e-rosa-sts-ovn"
)

format_job_line() {
  local display_name="$1" job_name="$2"
  local build_id
  build_id=$(curl -sf --max-time 10 "${GCS_BASE}/logs/${job_name}/latest-build.txt" 2>/dev/null || true)
  if [[ -z "${build_id}" ]]; then
    printf "%s:  :warning: NO DATA\n" "${display_name}"; return
  fi
  local result
  result=$(curl -sf --max-time 10 "${GCS_BASE}/logs/${job_name}/${build_id}/finished.json" 2>/dev/null | jq -r '.result // empty' 2>/dev/null || true)
  local link="${PROW_BASE}/logs/${job_name}/${build_id}"
  local icon
  case "${result}" in
    SUCCESS)  icon=":white_check_mark: PASS" ;;
    FAILURE)  icon=":x: FAIL" ;;
    ABORTED)  icon=":no_entry_sign: ABORTED" ;;
    "")       icon=":hourglass: RUNNING" ;;
    *)        icon=":question: ${result}" ;;
  esac
  printf "%s:  %s  (<%s|view>)\n" "${display_name}" "${icon}" "${link}"
}

today=$(date -u +"%Y-%m-%d")
tmpdir=$(mktemp -d); trap "rm -rf '${tmpdir}'" EXIT

idx=0
for entry in "${JOBS[@]}"; do
  (format_job_line "${entry%%|*}" "${entry##*|}" > "${tmpdir}/${idx}.txt") &
  idx=$((idx + 1))
done
wait

body=""
for i in $(seq 0 $((idx - 1))); do
  [[ -f "${tmpdir}/${i}.txt" ]] && body+="$(cat "${tmpdir}/${i}.txt")"$'\n'
done

message="*ROSA CI Daily Status (${today})*

${body}
_<https://prow.ci.openshift.org/?type=periodic&job=*rosa*|All ROSA periodic jobs>_ | _<https://sippy.dptools.openshift.org/rosa-stage/overview|Sippy>_"

response=$(curl -sf -X POST \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg channel "${SLACK_CHANNEL}" --arg text "${message}" '{channel: $channel, text: $text, unfurl_links: false, unfurl_media: false}')" \
  "https://slack.com/api/chat.postMessage")

if echo "${response}" | jq -e '.ok == true' > /dev/null 2>&1; then
  echo "Posted ROSA CI status to Slack successfully."
else
  echo "ERROR: Slack API error: $(echo "${response}" | jq -r '.error // "unknown"')" >&2; exit 1
fi
