#!/usr/bin/env bash

set -euo pipefail

readonly target_org="openshift-online"
readonly target_repo="gcp-hcp-infra"
readonly token_path="${GITHUB_TOKEN_PATH:-/etc/github-private/oauth}"
readonly tested_sha_path="${SHARED_DIR}/gcp-hcp-tested-sha"
readonly main_head_path="${SHARED_DIR}/gcp-hcp-main-head-at-start"

if [[ -z "${JOB_SPEC:-}" ]]; then
  echo "ERROR: JOB_SPEC is required to resolve the tested commit" >&2
  exit 1
fi

target_ref="$(jq -cer --arg org "${target_org}" --arg repo "${target_repo}" '
  [
    (.refs? | select(. != null) | . + {"_prow_primary_ref": true}),
    (.extra_refs[]? | . + {"_prow_primary_ref": false})
  ]
  | map(select(.org == $org and .repo == $repo))
  | if length == 1 then
      .[0]
    elif length == 0 then
      error("target repository not found in JOB_SPEC")
    else
      error("target repository appears more than once in JOB_SPEC")
    end
' <<<"${JOB_SPEC}")"

pull_count="$(jq -r '(.pulls // []) | length' <<<"${target_ref}")"
if (( pull_count > 1 )); then
  echo "ERROR: multiple pull refs found for the target repository" >&2
  exit 1
elif (( pull_count == 1 )); then
  tested_sha="$(jq -r '.pulls[0].sha' <<<"${target_ref}")"
else
  tested_sha="$(jq -r '.base_sha // empty' <<<"${target_ref}")"
fi

# Periodic extra refs are resolved by clonerefs at runtime, so their ProwJob
# metadata can omit base_sha. In that case use HEAD only after verifying this
# step is running in the target repository checkout.
if [[ -z "${tested_sha}" ]]; then
  if [[ "$(jq -r '._prow_primary_ref == true or .workdir == true' <<<"${target_ref}")" != "true" ]]; then
    echo "ERROR: target ref has no SHA and is not the active checkout" >&2
    exit 1
  fi

  # Prow marks this exact extra ref as the active workdir, but its checkout can
  # omit remote.origin.url. Resolve HEAD without depending on remote metadata.
  if ! tested_sha="$(git rev-parse HEAD 2>/dev/null)"; then
    echo "ERROR: unable to resolve HEAD from the active target checkout" >&2
    exit 1
  fi
fi

if [[ ! "${tested_sha}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: resolved commit SHA is not a full lowercase Git SHA" >&2
  exit 1
fi

if [[ ! "${PROW_JOB_ID:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "ERROR: PROW_JOB_ID is missing or invalid" >&2
  exit 1
fi

if [[ ! -s "${token_path}" ]]; then
  echo "ERROR: GitHub credential is missing or empty" >&2
  exit 1
fi

main_head="$(
  curl \
    --fail-with-body \
    --silent \
    --show-error \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $(<"${token_path}")" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${target_org}/${target_repo}/git/ref/heads/main" \
    | jq -er '.object.sha'
)"
if [[ ! "${main_head}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: main HEAD is not a full lowercase Git SHA" >&2
  exit 1
fi

readonly target_url="https://prow.ci.openshift.org/prowjob?prowjob=${PROW_JOB_ID}"
printf '%s\n' "${tested_sha}" >"${tested_sha_path}"
printf '%s\n' "${main_head}" >"${main_head_path}"
payload="$(jq -cn --arg target_url "${target_url}" '{
  state: "pending",
  context: "e2e/platform",
  description: "GCP HCP platform E2E test is running",
  target_url: $target_url
}')"

echo "Posting pending e2e/platform status to ${target_org}/${target_repo}@${tested_sha}"
curl \
  --fail-with-body \
  --silent \
  --show-error \
  --request POST \
  --header "Accept: application/vnd.github+json" \
  --header "Authorization: Bearer $(<"${token_path}")" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  --data "${payload}" \
  "https://api.github.com/repos/${target_org}/${target_repo}/statuses/${tested_sha}" \
  >/dev/null
echo "GitHub accepted the pending e2e/platform status"
