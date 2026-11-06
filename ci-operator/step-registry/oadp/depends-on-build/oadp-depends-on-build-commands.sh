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
#
# FETCH RESILIENCE: the anonymous GitHub API is frequently unreachable from
# build-farm step pods (their shared egress IP sits over GitHub's 60 req/hr
# anonymous limit; observed as an immediate failure in every CI run of this
# step so far -- e.g. the openshift/release#84228 and #88443 rehearsals and
# openshift/oadp-operator#2531's post-#84228 e2e-test-aws run, all failing
# this exact fetch before any test ran). A failed description fetch must NOT
# fail the whole job: every presubmit this step is wired into would go red
# before its own tests even start. So: retry direct, then retry through the
# TEST cluster's own egress (a different NAT IP than the build farm's), and
# only if every path fails, degrade to a no-op with a loud warning plus a
# marker artifact -- Depends-On resolution being down stays visible in the
# log and artifacts, while the job itself is unaffected.
echo "[$(date --utc +%FT%T.%3NZ)] Fetching PR description for ${REPO_OWNER}/${REPO_NAME}#${PULL_NUMBER}"
PR_API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/pulls/${PULL_NUMBER}"
CURL_HEADERS=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

fetch_pr_json() {
    # $1: "direct" or "via-test-cluster". Body -> /tmp/depends-on-pr.json,
    # curl stderr -> /tmp/depends-on-curl.err, http code -> stdout (direct
    # mode only; the pod mode validates by content instead).
    if [[ "${1}" == "direct" ]]; then
        curl -s -S -o /tmp/depends-on-pr.json -w '%{http_code}' "${CURL_HEADERS[@]}" "${PR_API_URL}" 2>/tmp/depends-on-curl.err
        return
    fi
    # Alternate egress: one-shot pod on the TEST cluster this step already
    # builds images in, whose NAT egress is a different IP than the build
    # farm's. Best effort -- an unpullable image or equally blocked egress
    # just falls through to the no-op path below.
    local POD="depends-on-fetch-$(date +%s)"
    timeout 150 oc run --rm -i --restart=Never --image=curlimages/curl "${POD}" -n "${OO_INSTALL_NAMESPACE}" -- \
        curl -sf "${CURL_HEADERS[@]}" "${PR_API_URL}" > /tmp/depends-on-pr.json 2>/tmp/depends-on-curl.err
}

PR_JSON=""
for MODE in direct via-test-cluster; do
    for ATTEMPT in 1 2 3; do
        set +o errexit
        if [[ "${MODE}" == "direct" ]]; then
            HTTP_CODE=$(fetch_pr_json direct)
        else
            HTTP_CODE=200
            fetch_pr_json via-test-cluster
        fi
        CURL_RC=$?
        set -o errexit
        if [[ "${CURL_RC}" -eq 0 && "${HTTP_CODE:-}" == "200" && -s /tmp/depends-on-pr.json ]] \
            && grep -q '"number"' /tmp/depends-on-pr.json; then
            PR_JSON=$(cat /tmp/depends-on-pr.json)
            break 2
        fi
        echo "[$(date --utc +%FT%T.%3NZ)] PR description fetch (${MODE}, attempt ${ATTEMPT}/3) failed: curl exit ${CURL_RC}, http ${HTTP_CODE:-none}, stderr: $(head -c 200 /tmp/depends-on-curl.err 2>/dev/null || echo none)" >&2
        sleep $((ATTEMPT * 5))
    done
done
rm -f /tmp/depends-on-pr.json /tmp/depends-on-curl.err

if [[ -z "${PR_JSON}" ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] WARNING: could not fetch the ${REPO_OWNER}/${REPO_NAME}#${PULL_NUMBER} description from the GitHub API after all attempts -- Depends-On resolution is DISABLED for this run; continuing as a no-op so the job is not failed by it" >&2
    echo "github-api-fetch-failed ${REPO_OWNER}/${REPO_NAME}#${PULL_NUMBER} $(date --utc +%FT%T.%3NZ)" >> "${ARTIFACT_DIR}/depends-on-fetch-failed.txt"
    exit 0
fi

# Isolate just the JSON "body" field before scanning for Depends-On lines --
# scanning the raw response risks a false match if the PR TITLE itself
# happens to contain "Depends-On: <url>" text (titles are also present in
# this response). No jq in this image (same reasoning as
# oadp-operator-sdk-bundle-image), so extract the escaped body value with
# grep -P instead of pulling in a full JSON parser for one field -- this
# image already assumes GNU coreutils (the `date --utc` calls throughout
# this script are GNU-only too), and GNU grep's PCRE support is standard on
# the RHEL/UBI base this image is built from.
# GitHub's API returns pretty-printed JSON ("body": "..." with a space
# after the colon), so the key match must tolerate that whitespace: a
# '"body":"' pattern never matched the real payload, leaving the extraction
# empty (and, under errexit+pipefail, failing the step via the grep no-match
# exit code) even on a successful fetch.
PR_BODY_ESCAPED=$(printf '%s' "${PR_JSON}" | grep -Po '"body": *"(\\.|[^"\\])*"' | head -1 || true)
# sed, not a bash glob strip: the glob's ' *' means one literal space plus
# wildcard, so it would miss a zero-space compact payload that the regex
# above does match -- same regex semantics on both sides.
PR_BODY_ESCAPED=$(printf '%s' "${PR_BODY_ESCAPED}" | sed -E 's/^"body": *"//')
PR_BODY_ESCAPED="${PR_BODY_ESCAPED%\"}"
DEPENDS_ON_LINES=$(printf '%s' "${PR_BODY_ESCAPED}" | grep -oiE 'depends-on:[^"\\]*https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' || true)

if [[ -z "${DEPENDS_ON_LINES}" ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] No Depends-On lines found in PR description -- nothing to resolve"
    exit 0
fi

echo "[$(date --utc +%FT%T.%3NZ)] Found Depends-On line(s):"
echo "${DEPENDS_ON_LINES}"

RESOLVED_ANY=false
SEEN_URLS=""

while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    DEP_URL=$(printf '%s' "${line}" | grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+')

    # Dedup by exact URL (a PR body accidentally repeating the identical
    # Depends-On line), NOT by repo -- one repo can legitimately match
    # several DEPENDS_ON_CANDIDATES lines below (e.g. oadp-vm-file-restore
    # builds 3 separate images from 3 different Dockerfiles in the same
    # repo, each feeding a different RELATED_IMAGE_* var), and all of those
    # must be built from this one PR checkout.
    if [[ " ${SEEN_URLS} " == *" ${DEP_URL} "* ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] ${DEP_URL} already processed from an earlier identical Depends-On line -- skipping duplicate"
        continue
    fi
    SEEN_URLS="${SEEN_URLS} ${DEP_URL}"

    DEP_REPO=$(printf '%s' "${DEP_URL}" | sed -E 's#https://github\.com/([^/]+/[^/]+)/pull/[0-9]+#\1#')
    DEP_PR=$(printf '%s' "${DEP_URL}" | sed -E 's#.*/pull/([0-9]+)#\1#')

    # Collect every DEPENDS_ON_CANDIDATES line naming this repo -- may be
    # more than one (see comment above), so this does NOT stop at the
    # first match.
    MATCHED_CANDIDATES=""
    while IFS= read -r CAND_LINE; do
        [[ -z "${CAND_LINE}" ]] && continue
        CAND_REPO=$(printf '%s' "${CAND_LINE}" | awk '{print $1}')
        [[ "${CAND_REPO}" == "${DEP_REPO}" ]] && MATCHED_CANDIDATES="${MATCHED_CANDIDATES}${CAND_LINE}
"
    done <<< "${DEPENDS_ON_CANDIDATES}"

    if [[ -z "${MATCHED_CANDIDATES}" ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] Depends-On ${DEP_REPO}#${DEP_PR} found, but ${DEP_REPO} is not a configured candidate for this job -- skipping"
        continue
    fi

    echo "[$(date --utc +%FT%T.%3NZ)] Fetching ${DEP_REPO}#${DEP_PR} once for $(printf '%s' "${MATCHED_CANDIDATES}" | grep -c .) matching candidate(s)"
    SRC_DIR=$(mktemp -d)
    TARBALL_URL="https://github.com/${DEP_REPO}/archive/refs/pull/${DEP_PR}/head.tar.gz"
    curl -sfL "${TARBALL_URL}" -o /tmp/depends-on-src.tar.gz
    tar xzf /tmp/depends-on-src.tar.gz -C "${SRC_DIR}" --strip-components=1
    rm -f /tmp/depends-on-src.tar.gz

    while IFS= read -r CAND_LINE; do
        [[ -z "${CAND_LINE}" ]] && continue
        # Third field is an optional Dockerfile path relative to the repo
        # root, for a repo whose default build target isn't a plain
        # "Dockerfile" (e.g. Dockerfile.ubi, Containerfile) -- mirrors that
        # repo's own dockerfile_path in its ci-operator config. Defaults to
        # "Dockerfile" when omitted.
        # Fourth field is an optional build-context directory relative to
        # the repo root (mirrors ci-operator's images[].context_dir), for a
        # repo whose image builds from a subdirectory. The Dockerfile path
        # is then relative to that directory, as in ci-operator. Defaults to
        # the repo root when omitted.
        read -r _ RELATED_ENV CAND_DOCKERFILE CAND_CONTEXT <<< "${CAND_LINE}"
        CAND_DOCKERFILE="${CAND_DOCKERFILE:-Dockerfile}"
        CAND_CONTEXT="${CAND_CONTEXT:-.}"
        if [[ "${CAND_CONTEXT}" == /* || "${CAND_CONTEXT}" == *..* ]]; then
            echo "[$(date --utc +%FT%T.%3NZ)] Invalid context dir '${CAND_CONTEXT}' for ${RELATED_ENV}: must be relative and not contain '..'" >&2
            rm -rf "${SRC_DIR}"
            exit 1
        fi
        BUILD_CONTEXT_DIR="${SRC_DIR}/${CAND_CONTEXT}"
        if [[ ! -d "${BUILD_CONTEXT_DIR}" ]]; then
            echo "[$(date --utc +%FT%T.%3NZ)] Context dir '${CAND_CONTEXT}' not found in ${DEP_REPO}#${DEP_PR}" >&2
            rm -rf "${SRC_DIR}"
            exit 1
        fi
        echo "[$(date --utc +%FT%T.%3NZ)] Resolving ${DEP_REPO}#${DEP_PR} (${CAND_DOCKERFILE}, context ${CAND_CONTEXT}) -> ${RELATED_ENV}"

        # Build entirely inside the target test cluster: a normal
        # OpenShift binary Build (buildah managed by OCP, nothing to
        # install locally) that uploads SRC_DIR as its input and lands the
        # result in this cluster's own internal registry as an
        # ImageStreamTag. No external route, insecure-registry marking, or
        # MachineConfigPool rollout needed -- unlike
        # oadp-operator-sdk-bundle-image's OO_MIRROR_TO_CLUSTER_REGISTRY
        # dance, the only consumer of this image is this same cluster's
        # own kubelet, which already trusts its own internal registry
        # natively.
        BUILD_NAME="depends-on-$(printf '%s' "${RELATED_ENV}" | tr '[:upper:]_' '[:lower:]-' | tr -c 'a-z0-9-' '-')"
        echo "[$(date --utc +%FT%T.%3NZ)] Creating BuildConfig/ImageStream ${BUILD_NAME} in ${OO_INSTALL_NAMESPACE}"
        oc new-build --strategy=docker --binary --name="${BUILD_NAME}" -n "${OO_INSTALL_NAMESPACE}"
        if [[ "${CAND_DOCKERFILE}" != "Dockerfile" ]]; then
            oc patch bc/"${BUILD_NAME}" -n "${OO_INSTALL_NAMESPACE}" --type merge \
              -p "{\"spec\":{\"strategy\":{\"dockerStrategy\":{\"dockerfilePath\":\"${CAND_DOCKERFILE}\"}}}}"
        fi

        echo "[$(date --utc +%FT%T.%3NZ)] Starting binary build ${BUILD_NAME} from ${BUILD_CONTEXT_DIR}"
        set +o errexit
        oc start-build "${BUILD_NAME}" --from-dir="${BUILD_CONTEXT_DIR}" --follow --wait -n "${OO_INSTALL_NAMESPACE}"
        BUILD_STATUS=$?
        set -o errexit

        if [[ "${BUILD_STATUS}" -ne 0 ]]; then
            echo "[$(date --utc +%FT%T.%3NZ)] Build ${BUILD_NAME} failed (exit ${BUILD_STATUS}) -- dumping diagnostics" >&2
            oc get build,bc -n "${OO_INSTALL_NAMESPACE}" -l "buildconfig=${BUILD_NAME}" || true
            oc logs "bc/${BUILD_NAME}" -n "${OO_INSTALL_NAMESPACE}" --all-containers || true
            rm -rf "${SRC_DIR}"
            exit "${BUILD_STATUS}"
        fi

        IMAGE_REF=$(oc get istag "${BUILD_NAME}:latest" -n "${OO_INSTALL_NAMESPACE}" -o jsonpath='{.image.dockerImageReference}')
        if [[ -z "${IMAGE_REF}" ]]; then
            echo "[$(date --utc +%FT%T.%3NZ)] Failed to resolve pullspec for ${BUILD_NAME}:latest" >&2
            rm -rf "${SRC_DIR}"
            exit 1
        fi
        echo "[$(date --utc +%FT%T.%3NZ)] ${DEP_REPO}#${DEP_PR} (${CAND_DOCKERFILE}) built, exposing via ${RELATED_ENV} (pullspec written to ${SHARED_DIR}/depends-on-images.txt, not logged -- internal cluster registry address)"
        echo "${RELATED_ENV} ${IMAGE_REF}" >> "${SHARED_DIR}/depends-on-images.txt"
        RESOLVED_ANY=true
    done <<< "${MATCHED_CANDIDATES}"
    rm -rf "${SRC_DIR}"
done <<< "${DEPENDS_ON_LINES}"

if [[ "${RESOLVED_ANY}" != "true" ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] Depends-On line(s) found, but none matched a configured candidate for this job -- nothing to resolve"
fi
