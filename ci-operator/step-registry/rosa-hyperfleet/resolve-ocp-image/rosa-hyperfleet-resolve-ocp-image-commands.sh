#!/bin/bash

set -euo pipefail

# Resolves OCP_RELEASE_STREAM to the latest accepted payload of a release
# controller stream and writes its pullspec to ${SHARED_DIR}/ocp-image, where
# rosa-hyperfleet-e2e picks it up.
#
# OCP_RELEASE_STREAM values (see the ref documentation for details):
#   ""                    do nothing; the e2e step uses its default image
#   ocp-branch-nightly    newest X.Y.0-0.nightly-multi payload, X.Y at most
#                         the release-X.Y branch's version
#   ocp-branch-candidate  newest GA/RC payload from the N-stable-multi streams,
#                         X.Y at most the release-X.Y branch's version
#   <stream>              that stream as-is, e.g. 5.1.0-0.nightly-multi
# The ocp-branch-* values are only for repos whose branches follow OCP
# versions; on other branches (e.g. main) they use the newest X.Y.

if [[ -z "${OCP_RELEASE_STREAM:-}" ]]; then
  echo "OCP_RELEASE_STREAM is not set, nothing to resolve."
  exit 0
fi

MULTI_RELEASE_CONTROLLER="https://multi.ocp.releases.ci.openshift.org"
AMD64_RELEASE_CONTROLLER="https://amd64.ocp.releases.ci.openshift.org"

# Each attempt is time-bounded, so a stalled connection is retried instead of
# hanging the step.
fetch() {
  curl -sSf --connect-timeout 10 --max-time 60 --retry 5 --retry-delay 10 "$1"
}

# Prints "<X.Y> <stream>" for the highest OCP X.Y with an accepted payload in
# the multi-arch streams matching the regex $1, limited to X.Y <= $2 when $2 is
# set. Prints nothing when no stream qualifies. Streams without accepted
# releases are null in the API response and are skipped, so an empty new stream
# does not break the fallback to older ones.
newest_version_at_most() {
  fetch "${MULTI_RELEASE_CONTROLLER}/api/v1/releasestreams/accepted" | jq -r \
    --arg streams "$1" --arg max "$2" '
    [to_entries[]
     | select(.key | test($streams))
     | .key as $stream
     | (.value // [])[]
     | capture("^(?<major>[0-9]+)\\.(?<minor>[0-9]+)\\.")
     | {version: [(.major | tonumber), (.minor | tonumber)], stream: $stream}]
    | map(select($max == "" or .version <= ($max | split(".") | map(tonumber))))
    | max_by(.version)
    | select(. != null)
    | "\(.version | join(".")) \(.stream)"'
}

# Prints the base_ref of the repo under test, the way ci-operator/clonerefs
# picks the working repo: the ref marked workdir:true wins. This matters in
# pj-rehearse, where .refs points at openshift/release@main and the repo under
# test is an extra_ref with workdir:true -- reading .refs.base_ref there would
# yield "main" and silently resolve the newest version. Falls back to .refs,
# then the first extra_ref, for presubmits and periodics without an explicit
# workdir.
branch_under_test() {
  jq -r '
    [.refs] + (.extra_refs // [])
    | map(select(. != null))
    | ((map(select(.workdir == true)) | first) // .[0] // {})
    | .base_ref // empty
  ' <<< "${JOB_SPEC:-}"
}

# "ocp-branch-<kind>": sets STREAM (and PREFIX for candidates) to the newest
# payload of the release-X.Y branch's OCP version, assuming release-5.1 tests
# OCP 5.1. Falls back to the newest older X.Y that has one (e.g. right after a
# branch cut), so a branch never tests a newer OCP than its own. Other
# branches (e.g. main) get the newest X.Y.
#   nightly:   X.Y.0-0.nightly-multi
#   candidate: N-stable-multi, which only holds GA, z-stream and RC payloads
resolve_ocp_branch() {
  local kind="$1" streams branch target="" result version stream
  case "${kind}" in
    nightly)   streams='^[0-9]+\.[0-9]+\.0-0\.nightly-multi$' ;;
    candidate) streams='^[0-9]+-stable-multi$' ;;
  esac

  branch="$(branch_under_test)"
  if [[ "${branch}" =~ ^release-([0-9]+\.[0-9]+)$ ]]; then
    target="${BASH_REMATCH[1]}"
  else
    echo "Branch '${branch}' is not release-X.Y, using the newest OCP version" >&2
  fi

  if ! result="$(newest_version_at_most "${streams}" "${target}")"; then
    echo "ERROR: could not list accepted streams from ${MULTI_RELEASE_CONTROLLER}" >&2
    exit 1
  fi
  if [[ -z "${result}" ]]; then
    echo "ERROR: no accepted ${kind} payload found${target:+ for OCP ${target} or older}" >&2
    exit 1
  fi
  read -r version stream <<< "${result}"
  if [[ -n "${target}" && "${version}" != "${target}" ]]; then
    echo "WARNING: no accepted ${kind} payload for OCP ${target} yet, using OCP ${version}" >&2
  fi

  STREAM="${stream}"
  if [[ "${kind}" == candidate ]]; then
    PREFIX="${version}."
  fi
}

STREAM=""
PREFIX=""
case "${OCP_RELEASE_STREAM}" in
  ocp-branch-nightly)   resolve_ocp_branch nightly ;;
  ocp-branch-candidate) resolve_ocp_branch candidate ;;
  *)                    STREAM="${OCP_RELEASE_STREAM}" ;;
esac
if [[ "${STREAM}" != "${OCP_RELEASE_STREAM}" ]]; then
  echo "OCP_RELEASE_STREAM=${OCP_RELEASE_STREAM} resolved to ${STREAM}${PREFIX:+ (${PREFIX}*)}"
fi

if [[ "${STREAM}" == *-multi ]]; then
  RELEASE_CONTROLLER="${MULTI_RELEASE_CONTROLLER}"
else
  RELEASE_CONTROLLER="${AMD64_RELEASE_CONTROLLER}"
fi

echo "Resolving the latest accepted payload of ${STREAM}${PREFIX:+ matching ${PREFIX}*}..."
if ! RELEASE="$(fetch "${RELEASE_CONTROLLER}/api/v1/releasestream/${STREAM}/latest${PREFIX:+?prefix=${PREFIX}}")"; then
  echo "ERROR: could not get stream ${STREAM} from ${RELEASE_CONTROLLER}." >&2
  echo "Use ocp-branch-nightly, ocp-branch-candidate or a stream name listed there." >&2
  exit 1
fi
OCP_IMAGE="$(jq -r '.pullSpec // empty' <<< "${RELEASE}")"
if [[ -z "${OCP_IMAGE}" ]]; then
  echo "ERROR: no accepted payload found in stream ${STREAM}" >&2
  exit 1
fi

echo "Using $(jq -r '.name' <<< "${RELEASE}"): ${OCP_IMAGE}"
echo "${OCP_IMAGE}" > "${SHARED_DIR}/ocp-image"
echo "${RELEASE}" > "${ARTIFACT_DIR}/ocp-release.json"
