#!/bin/bash

# Generic N-candidate Depends-On resolver (openshift/oadp-operator#2389),
# following the same PR-description convention already used by
# ci-operator/step-registry/openstack-k8s-operators/kuttl. Unlike that step
# (source checkout only), a resolved dependency here becomes a real pushed
# container image, since downstream needs an actual pullspec (a Kubernetes
# Subscription's RELATED_IMAGE_* override).
#
# ORDER OF OPERATIONS for a multi-repo PR author (e.g. testing a
# kdm-controller PR together with an unmerged kdm-plugin PR):
#
#   1. Open (or already have open) a PR in EACH repo you want tested
#      together.
#   2. Only THIS step's OWN triggering PR's description is ever read here --
#      REPO_OWNER/REPO_NAME/PULL_NUMBER below identify it. The repo(s) named
#      in its Depends-On line(s) are never asked "do you depend on this PR
#      back?" -- a depended-on PR needs ZERO changes, no reciprocal marker,
#      nothing added to it at all.
#   3. This is ONE-DIRECTIONAL by default: adding a Depends-On line to
#      the kdm-controller PR only makes the kdm-controller job pull in the
#      kdm-plugin PR. It does NOT make the kdm-plugin job pull in the
#      kdm-controller PR back -- that job resolves Depends-On from ITS OWN
#      PR's description, which is a different PR with a different body.
#      For a SYMMETRIC combo (both jobs testing both PRs together), add a
#      Depends-On line to BOTH PRs, each pointing at the other.
#   4. Depends-On can be added, edited, or removed at any time, including
#      well after the PR was first opened -- this step always fetches the
#      CURRENT PR body live from the GitHub API (below) at the moment the
#      job actually runs, not at PR-open time or from any cached/webhook
#      payload. So: add/edit the Depends-On line, then `/test <job-name>`
#      (or `/retest`, or just push again) -- no special re-trigger dance,
#      the very next run picks it up.
#   5. Nothing here re-runs automatically when the DEPENDED-ON PR gets a new
#      push -- only the triggering PR's own presubmit re-run (a new commit,
#      `/retest`, or an explicit `/test <job-name>`) re-resolves, and it
#      re-resolves to whatever that PR's HEAD is AT THAT MOMENT.

set -o nounset
set -o errexit
set -o pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Checking/installing oc..."
if ! command -v oc &> /dev/null; then
    curl -L https://openshift-mirror-list.ci-systems.workers.dev/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz -o /tmp/oc.tar.gz && tar xzvf /tmp/oc.tar.gz -C /tmp
    export PATH="/tmp:${PATH}"
fi
oc version --client

# Prow injects these flat env vars for presubmit jobs directly -- no JSON
# parsing (jq or otherwise) needed to identify the triggering PR. This step
# is only ever wired into presubmit test configs, so requiring them is a
# feature (fails loudly if ever misused from a different job type) rather
# than a limitation.
: "${REPO_OWNER:?REPO_OWNER not set -- oadp-depends-on-build only makes sense on a presubmit}"
: "${REPO_NAME:?REPO_NAME not set -- oadp-depends-on-build only makes sense on a presubmit}"
: "${PULL_NUMBER:?PULL_NUMBER not set -- oadp-depends-on-build only makes sense on a presubmit}"

# Live fetch, not a cached/webhook copy: this is what makes step 4 above
# ("edit Depends-On after the fact, then /test") work -- every run of this
# step re-reads whatever the PR description says right now.
echo "[$(date --utc +%FT%T.%3NZ)] Fetching PR description for ${REPO_OWNER}/${REPO_NAME}#${PULL_NUMBER}"
PR_JSON=$(curl -sf -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/pulls/${PULL_NUMBER}")

# No jq in this image (same reasoning as oadp-operator-sdk-bundle-image):
# rather than isolate the JSON "body" field first, grep the raw response
# directly for the pattern we actually care about. JSON string escaping
# only touches quotes/backslashes/control characters, so a plain
# "Depends-On: https://github.com/<org>/<repo>/pull/<N>" line inside the PR
# body appears byte-for-byte in the raw response; no other field on a
# single-PR API response (url, title, user, head, base, ...) can contain
# that literal pattern, so this is safe without a full JSON parse.
DEPENDS_ON_LINES=$(printf '%s' "${PR_JSON}" | grep -oiE 'depends-on:[^"\\]*https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' || true)

if [[ -z "${DEPENDS_ON_LINES}" ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] No Depends-On lines found in PR description -- nothing to resolve"
    exit 0
fi

echo "[$(date --utc +%FT%T.%3NZ)] Found Depends-On line(s):"
echo "${DEPENDS_ON_LINES}"

RESOLVED_ANY=false
SEEN_REPOS=""

while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    DEP_URL=$(printf '%s' "${line}" | grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+')
    DEP_REPO=$(printf '%s' "${DEP_URL}" | sed -E 's#https://github\.com/([^/]+/[^/]+)/pull/[0-9]+#\1#')
    DEP_PR=$(printf '%s' "${DEP_URL}" | sed -E 's#.*/pull/([0-9]+)#\1#')

    if [[ " ${SEEN_REPOS} " == *" ${DEP_REPO} "* ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] ${DEP_REPO} already resolved from an earlier Depends-On line -- skipping duplicate"
        continue
    fi

    RELATED_ENV=""
    while read -r CAND_REPO CAND_ENV; do
        [[ -z "${CAND_REPO}" ]] && continue
        if [[ "${CAND_REPO}" == "${DEP_REPO}" ]]; then
            RELATED_ENV="${CAND_ENV}"
            break
        fi
    done <<< "${DEPENDS_ON_CANDIDATES}"

    if [[ -z "${RELATED_ENV}" ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] Depends-On ${DEP_REPO}#${DEP_PR} found, but ${DEP_REPO} is not a configured candidate for this job -- skipping"
        continue
    fi

    SEEN_REPOS="${SEEN_REPOS} ${DEP_REPO}"
    echo "[$(date --utc +%FT%T.%3NZ)] Resolving ${DEP_REPO}#${DEP_PR} -> ${RELATED_ENV}"

    SRC_DIR=$(mktemp -d)
    TARBALL_URL="https://github.com/${DEP_REPO}/archive/refs/pull/${DEP_PR}/head.tar.gz"
    echo "[$(date --utc +%FT%T.%3NZ)] Fetching ${TARBALL_URL}"
    curl -sfL "${TARBALL_URL}" -o /tmp/depends-on-src.tar.gz
    tar xzf /tmp/depends-on-src.tar.gz -C "${SRC_DIR}" --strip-components=1
    rm -f /tmp/depends-on-src.tar.gz

    # Build entirely inside the target test cluster: a normal OpenShift
    # binary Build (buildah managed by OCP, nothing to install locally) that
    # uploads SRC_DIR as its input and lands the result in this cluster's
    # own internal registry as an ImageStreamTag. No external route,
    # insecure-registry marking, or MachineConfigPool rollout needed --
    # unlike oadp-operator-sdk-bundle-image's OO_MIRROR_TO_CLUSTER_REGISTRY
    # dance, the only consumer of this image is this same cluster's own
    # kubelet, which already trusts its own internal registry natively.
    BUILD_NAME="depends-on-$(basename "${DEP_REPO}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
    echo "[$(date --utc +%FT%T.%3NZ)] Creating BuildConfig/ImageStream ${BUILD_NAME} in ${OO_INSTALL_NAMESPACE}"
    oc new-build --strategy=docker --binary --name="${BUILD_NAME}" -n "${OO_INSTALL_NAMESPACE}"

    echo "[$(date --utc +%FT%T.%3NZ)] Starting binary build ${BUILD_NAME} from ${SRC_DIR}"
    set +o errexit
    oc start-build "${BUILD_NAME}" --from-dir="${SRC_DIR}" --follow --wait -n "${OO_INSTALL_NAMESPACE}"
    BUILD_STATUS=$?
    set -o errexit
    rm -rf "${SRC_DIR}"

    if [[ "${BUILD_STATUS}" -ne 0 ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] Build ${BUILD_NAME} failed (exit ${BUILD_STATUS}) -- dumping diagnostics" >&2
        oc get build,bc -n "${OO_INSTALL_NAMESPACE}" -l "buildconfig=${BUILD_NAME}" || true
        oc logs "bc/${BUILD_NAME}" -n "${OO_INSTALL_NAMESPACE}" --all-containers || true
        exit "${BUILD_STATUS}"
    fi

    IMAGE_REF=$(oc get istag "${BUILD_NAME}:latest" -n "${OO_INSTALL_NAMESPACE}" -o jsonpath='{.image.dockerImageReference}')
    if [[ -z "${IMAGE_REF}" ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] Failed to resolve pullspec for ${BUILD_NAME}:latest" >&2
        exit 1
    fi
    echo "[$(date --utc +%FT%T.%3NZ)] ${DEP_REPO}#${DEP_PR} built as ${IMAGE_REF}, exposing via ${RELATED_ENV}"
    echo "${RELATED_ENV} ${IMAGE_REF}" >> "${SHARED_DIR}/depends-on-images.txt"
    RESOLVED_ANY=true
done <<< "${DEPENDS_ON_LINES}"

if [[ "${RESOLVED_ANY}" != "true" ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] Depends-On line(s) found, but none matched a configured candidate for this job -- nothing to resolve"
fi
