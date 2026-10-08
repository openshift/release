#!/bin/bash

set -euo pipefail

# Resolves OCP_RELEASE_STREAM to the latest accepted payload of a release
# controller stream and writes its pullspec to ${SHARED_DIR}/ocp-image, where
# rosa-hyperfleet-e2e picks it up.
#
# OCP_RELEASE_STREAM values (see the ref documentation for details):
#   ""            do nothing; the e2e step uses its default image
#   latest        newest multi-arch nightly stream with an accepted payload
#   ocp-branch    X.Y.0-0.nightly-multi for a release-X.Y branch, else latest;
#                 only for repos whose branches follow OCP versions
#   <stream>      that stream as-is, e.g. 5.1.0-0.nightly-multi

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

# Prints the multi-arch nightly streams (X.Y.0-0.nightly-multi) that have at
# least one accepted payload, oldest version first.
accepted_multi_nightly_streams() {
  fetch "${MULTI_RELEASE_CONTROLLER}/api/v1/releasestreams/accepted" | jq -r '
    [to_entries[]
     | select(.key | test("^[0-9]+\\.[0-9]+\\.0-0\\.nightly-multi$"))
     | select(.value | length > 0)
     | .key]
    | sort_by(split(".")[0:2] | map(tonumber))
    | .[]'
}

# "latest": the newest multi-arch nightly stream with an accepted payload.
latest_stream() {
  accepted_multi_nightly_streams | tail -n 1
}

# Prints the base_ref of the repo under test, the way ci-operator/clonerefs
# picks the working repo: the ref marked workdir:true wins. This matters in
# pj-rehearse, where .refs points at openshift/release@main and the repo under
# test is an extra_ref with workdir:true -- reading .refs.base_ref there would
# yield "main" and silently fall back to "latest". Falls back to .refs, then
# the first extra_ref, for presubmits and periodics without an explicit workdir.
branch_under_test() {
  jq -r '
    [.refs] + (.extra_refs // [])
    | map(select(. != null))
    | ((map(select(.workdir == true)) | first) // .[0] // {})
    | .base_ref // empty
  ' <<< "${JOB_SPEC:-}"
}

# "ocp-branch": the nightly stream matching a release-X.Y branch under test.
# Assumes the branch name is an OCP version, so release-5.1 tests OCP 5.1.
# Falls back to "latest" for other branches (e.g. main) and for releases
# without an accepted nightly yet (e.g. right after a branch cut).
ocp_branch_stream() {
  local branch branch_stream
  branch="$(branch_under_test)"

  if [[ "${branch}" =~ ^release-([0-9]+\.[0-9]+)$ ]]; then
    branch_stream="${BASH_REMATCH[1]}.0-0.nightly-multi"
    if accepted_multi_nightly_streams | grep -qxF "${branch_stream}"; then
      echo "${branch_stream}"
      return
    fi
    echo "WARNING: ${branch_stream} has no accepted payload yet, using latest" >&2
  else
    echo "Branch '${branch}' is not release-X.Y, using latest" >&2
  fi
  latest_stream
}

case "${OCP_RELEASE_STREAM}" in
  latest)     STREAM="$(latest_stream)" ;;
  ocp-branch) STREAM="$(ocp_branch_stream)" ;;
  *)          STREAM="${OCP_RELEASE_STREAM}" ;;
esac
if [[ -z "${STREAM}" ]]; then
  echo "ERROR: no multi-arch nightly stream with an accepted payload found" >&2
  exit 1
fi
if [[ "${STREAM}" != "${OCP_RELEASE_STREAM}" ]]; then
  echo "OCP_RELEASE_STREAM=${OCP_RELEASE_STREAM} resolved to ${STREAM}"
fi

if [[ "${STREAM}" == *-multi ]]; then
  RELEASE_CONTROLLER="${MULTI_RELEASE_CONTROLLER}"
else
  RELEASE_CONTROLLER="${AMD64_RELEASE_CONTROLLER}"
fi

echo "Resolving the latest accepted payload of ${STREAM}..."
if ! RELEASE="$(fetch "${RELEASE_CONTROLLER}/api/v1/releasestream/${STREAM}/latest")"; then
  echo "ERROR: could not get stream ${STREAM} from ${RELEASE_CONTROLLER}." >&2
  echo "Use latest, ocp-branch or a stream name listed there." >&2
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
