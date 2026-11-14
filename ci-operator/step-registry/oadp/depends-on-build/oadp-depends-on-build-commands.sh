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
# mktemp, not fixed /tmp names: predictable paths are symlink/TOCTOU-hijackable
# (CWE-377), and unique files also cannot collide across retries.
TMP_PR_JSON=$(mktemp)
TMP_CURL_ERR=$(mktemp)

fetch_pr_json() {
    # $1: "direct" or "via-test-cluster". Body -> ${TMP_PR_JSON}, curl stderr
    # -> ${TMP_CURL_ERR}, http code -> stdout (direct mode only; the pod mode
    # validates by content instead). Both curls are time-bounded so a stalled
    # connection cannot block the remaining fallback attempts or the no-op
    # path.
    if [[ "${1}" == "direct" ]]; then
        curl -s -S --connect-timeout 10 --max-time 60 -o "${TMP_PR_JSON}" -w '%{http_code}' "${CURL_HEADERS[@]}" "${PR_API_URL}" 2>"${TMP_CURL_ERR}"
        return
    fi
    # Alternate egress: one-shot pod on the TEST cluster this step already
    # builds images in, whose NAT egress is a different IP than the build
    # farm's. Best effort -- an unpullable image or equally blocked egress
    # just falls through to the no-op path below.
    local POD
    POD="depends-on-fetch-$(date +%s)"
    timeout 150 oc run --rm -i --restart=Never --image=curlimages/curl "${POD}" -n "${OO_INSTALL_NAMESPACE}" -- \
        curl -sf --connect-timeout 10 --max-time 120 "${CURL_HEADERS[@]}" "${PR_API_URL}" > "${TMP_PR_JSON}" 2>"${TMP_CURL_ERR}"
}

# Best-effort GitHub API GET for the optional guards below (the dep-PR
# branch check, the cherry-pick original lookup): direct curl first, then
# one attempt through the TEST cluster's own egress -- the same two-path
# shape and reasoning as the description fetch above, because the build
# farm's shared egress IP is routinely over GitHub's anonymous rate limit
# while the test cluster's NAT is not. Echoes the response body on
# success, returns 1 silently on failure; every caller treats a failed
# metadata fetch as "guard inconclusive, proceed as before" rather than
# failing the job -- an optional safety check must never be the reason a
# job goes red.
gh_api_get() {
    # $1: full https://api.github.com/... URL
    local URL="${1}" OUT
    OUT=$(mktemp)
    # No --retry here: the pod fallback below is the retry, and it uses a
    # different egress. Retrying a rate-limited direct call only stacks up
    # to three 60s attempts before that fallback even starts.
    if curl -sf --connect-timeout 10 --max-time 60 "${CURL_HEADERS[@]}" "${URL}" -o "${OUT}" 2>/dev/null; then
        cat "${OUT}"
        rm -f "${OUT}"
        return 0
    fi
    if [[ -n "${OO_INSTALL_NAMESPACE:-}" ]]; then
        local POD
        POD="depends-on-api-$(date +%s)"
        if timeout 150 oc run --rm -i --restart=Never --image=curlimages/curl "${POD}" -n "${OO_INSTALL_NAMESPACE}" -- \
            curl -sf --connect-timeout 10 --max-time 120 "${CURL_HEADERS[@]}" "${URL}" > "${OUT}" 2>/dev/null; then
            cat "${OUT}"
            rm -f "${OUT}"
            return 0
        fi
    fi
    rm -f "${OUT}"
    return 1
}

# Which channel a branch name denotes. The OADP repos do NOT all name their
# development branch `oadp-dev` -- migtools/kubevirt-velero-plugin and
# openshift/hypershift-oadp-plugin use `main`, and some repos still carry a
# `master` -- so the development-channel names are normalized to one token
# before a dep PR's base branch is compared with this job's PULL_BASE_REF.
# Without this, a dep PR on one of those repos' development branch is
# wrongly classified as unshippable in an `oadp-dev` job and silently
# skipped. Release branches (oadp-1.x, release-4.x) have no aliases and
# still compare by name.
branch_channel() {
    case "${1}" in
        oadp-dev|main|master) printf 'dev' ;;
        *) printf '%s' "${1}" ;;
    esac
}

# JSON "body" value of a PR API response, still JSON-escaped. Only the body
# field is ever scanned: the raw response also contains the title, where a
# literal "Depends-On: <url>" example could false-match.
extract_pr_body() {
    printf '%s' "${1}" | grep -Po '"body": *"(\\.|[^"\\])*"' | head -1 | sed -E 's/^"body": *"//; s/"$//' || true
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
        if [[ "${CURL_RC}" -eq 0 && "${HTTP_CODE:-}" == "200" && -s "${TMP_PR_JSON}" ]] \
            && grep -q '"number"' "${TMP_PR_JSON}"; then
            PR_JSON=$(cat "${TMP_PR_JSON}")
            break 2
        fi
        echo "[$(date --utc +%FT%T.%3NZ)] PR description fetch (${MODE}, attempt ${ATTEMPT}/3) failed: curl exit ${CURL_RC}, http ${HTTP_CODE:-none}, stderr: $(head -c 200 "${TMP_CURL_ERR}" 2>/dev/null || echo none)" >&2
        sleep $((ATTEMPT * 5))
    done
done
rm -f "${TMP_PR_JSON}" "${TMP_CURL_ERR}"

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
# the RHEL/UBI base this image is built from. extract_pr_body (above) also
# tolerates GitHub's pretty-printed '"body": "..."' whitespace and its sed
# mirrors the regex, so a zero-space compact payload is handled the same
# way; it is deliberately `|| true`-terminal because under errexit+pipefail
# a grep no-match (e.g. a null body) would otherwise fail the step.
PR_BODY_ESCAPED=$(extract_pr_body "${PR_JSON}")
DEPENDS_ON_LINES=$(printf '%s' "${PR_BODY_ESCAPED}" | grep -oiE 'depends-on:[^"\\]*https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' || true)

if [[ -z "${DEPENDS_ON_LINES}" ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] No Depends-On lines found in PR description -- nothing to resolve"

    # Cherry-pick enrichment: automated cherry-pick PRs (the openshift
    # cherry-pick robot, GitHub's backport bot) open with a fresh body and
    # do NOT copy the original PR's description, so any Depends-On lines
    # the original declared are silently lost -- this step no-ops and the
    # cherry-pick gets tested alone, which is exactly how a tested-together
    # pair ships broken. When this body carries standard cherry-pick/backport
    # wording, fetch the ORIGINAL PR's description once and surface the
    # Depends-On lines it declares in the log and an artifact: a pointer
    # for the author/reviewer to re-add the lines to THIS PR's description
    # (a quick body edit + /test re-runs them). Deliberately NOT acted on
    # -- only this PR's own description is ever resolved, so the trigger
    # semantics above are unchanged. Matches both the robot's same-repo
    # form ("This is an automated cherry-pick of #N") and the cross-repo
    # backport convention ("Cherry-pick of <org>/<repo>#N"); prose forms
    # like "cherry-pick of the resolved backport ..." do not match, by
    # design (the ref must directly follow the wording).
    CHERRY_REF=$(printf '%s' "${PR_BODY_ESCAPED}" | grep -oiE '(cherry-pick|backport) of (pull request |pr )?[A-Za-z0-9_./-]*#[0-9]+' | grep -oE '([A-Za-z0-9_.-]+/)?[A-Za-z0-9_.-]*#[0-9]+' | head -1 || true)
    CHERRY_ORIG_REPO="${REPO_OWNER}/${REPO_NAME}"
    CHERRY_ORIG_PR=""
    if [[ "${CHERRY_REF}" == */* ]]; then
        CHERRY_ORIG_REPO="${CHERRY_REF%#*}"
        CHERRY_ORIG_PR="${CHERRY_REF##*#}"
    elif [[ -n "${CHERRY_REF}" ]]; then
        CHERRY_ORIG_PR="${CHERRY_REF##*#}"
    fi
    if [[ -n "${CHERRY_ORIG_PR}" ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] Body looks like an automated cherry-pick of ${CHERRY_ORIG_REPO}#${CHERRY_ORIG_PR} -- checking whether the original PR declared Depends-On lines this body no longer carries"
        if ORIG_PR_JSON=$(gh_api_get "https://api.github.com/repos/${CHERRY_ORIG_REPO}/pulls/${CHERRY_ORIG_PR}"); then
            # Same escaped-body extraction as above (the title-vs-body
            # false-match avoidance applies to the original PR's response
            # too).
            ORIG_BODY_ESCAPED=$(extract_pr_body "${ORIG_PR_JSON}")
            ORIG_DEPENDS_ON=$(printf '%s' "${ORIG_BODY_ESCAPED}" | grep -oiE 'depends-on:[^"\\]*https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' || true)
            if [[ -n "${ORIG_DEPENDS_ON}" ]]; then
                echo "[$(date --utc +%FT%T.%3NZ)] WARNING: this cherry-pick carries no Depends-On lines, but the original ${CHERRY_ORIG_REPO}#${CHERRY_ORIG_PR} declares:" >&2
                printf '%s\n' "${ORIG_DEPENDS_ON}" | sed 's/^/  /' >&2
                echo "[$(date --utc +%FT%T.%3NZ)] Re-add the line(s) to THIS PR's description and /test <job-name> to have them resolved here -- they are not resolved automatically" >&2
                # Diagnostic only: a failed artifact write must never fail the
                # job (same "an optional check never turns the job red"
                # contract as the rest of this step).
                { echo "cherry-pick-of ${CHERRY_ORIG_REPO}#${CHERRY_ORIG_PR} declares Depends-On lines missing from this PR's body $(date --utc +%FT%T.%3NZ)"; printf '%s\n' "${ORIG_DEPENDS_ON}"; } >> "${ARTIFACT_DIR}/depends-on-cherrypick-original.txt" \
                    || echo "[$(date --utc +%FT%T.%3NZ)] WARNING: could not write ${ARTIFACT_DIR}/depends-on-cherrypick-original.txt" >&2
            else
                echo "[$(date --utc +%FT%T.%3NZ)] Original ${CHERRY_ORIG_REPO}#${CHERRY_ORIG_PR} declares no Depends-On lines either -- nothing was lost in the cherry-pick"
            fi
        else
            echo "[$(date --utc +%FT%T.%3NZ)] WARNING: could not fetch the original ${CHERRY_ORIG_REPO}#${CHERRY_ORIG_PR} description -- cherry-pick Depends-On check inconclusive" >&2
        fi
    fi
    exit 0
fi

echo "[$(date --utc +%FT%T.%3NZ)] Found Depends-On line(s):"
echo "${DEPENDS_ON_LINES}"

RESOLVED_ANY=false
MISMATCH_SKIPPED=false
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

    # Branch-mismatch guard: never build a dependency whose PR is based on
    # a different branch than the one this job tests. All OADP-ecosystem
    # repos use the same DEVELOPMENT-channel names modulo aliases (most:
    # oadp-dev; migtools/kubevirt-velero-plugin and
    # openshift/hypershift-oadp-plugin: main; some: master) and their
    # release branches are the same oadp-1.x names, so the two base refs are
    # comparable after branch_channel() normalizes the development aliases:
    # an oadp-dev-based dep PR pulled into an oadp-1.6 job would build a
    # combination that can never ship (dev code inside a release bundle),
    # and the resulting verdict -- pass OR fail -- says nothing about
    # either branch. On mismatch the dep is SKIPPED: this job proceeds
    # against the released, pre-built dependency, i.e. the combination
    # that actually ships, with a loud warning and a marker artifact
    # naming the dep and both branches. Best-effort like the description
    # fetch: if the dep PR's metadata cannot be fetched (or its base
    # branch cannot be extracted), the guard is inconclusive and the dep
    # is built as before -- a safety check must never be the reason a job
    # goes red. This also catches the common cherry-pick foot-gun: a
    # Depends-On line still pointing at the ORIGINAL (dev-branch) PR after
    # its change was cherry-picked to the release branch this job tests.
    # NOT applied in pj-rehearse runs, detected as: the triggering PR
    # lives in openshift/release itself (no real release-repo job wires
    # this step) -- a rehearsal's PULL_BASE_REF names the RELEASE repo's
    # branch, a namespace with no counterpart in the OADP repos' branch
    # scheme, so every dep would "mismatch" and the positive path could
    # never be rehearsed.
    DEP_BASE_REF=""
    # The dep PR's head commit, extracted from the same metadata fetch:
    # pins the source URL below to an immutable revision so a push to
    # the dep PR between this step's fetch and the e2e step's own
    # tarball fetch can never mix revisions (manager image from the old
    # head, test code from the new one). Initialized outside the guard
    # below so a skipped guard (rehearsal) never sees a stale value from
    # an earlier dependency in this loop.
    DEP_HEAD_SHA=""
    if [[ -n "${PULL_BASE_REF:-}" && "${REPO_OWNER}/${REPO_NAME}" != "openshift/release" ]]; then
        # Progress line before the fetch: the direct API path can fall back
        # to a one-shot pod, so this call is not always fast.
        echo "[$(date --utc +%FT%T.%3NZ)] Checking the base branch of ${DEP_REPO}#${DEP_PR} before fetching its source"
        if DEP_PR_JSON=$(gh_api_get "https://api.github.com/repos/${DEP_REPO}/pulls/${DEP_PR}"); then
            # The "base" object's "ref" field sits before its nested
            # user/repo objects in GitHub's payload, so grep -P over the
            # newline-flattened JSON picks it out (no jq in this image,
            # same as the body extraction above).
            DEP_BASE_REF=$(printf '%s' "${DEP_PR_JSON}" | tr -d '\n' \
                | grep -Po '"base": *\{[^{]*"ref": *"[^"]*"' \
                | grep -Po '"ref": *"[^"]*"$' \
                | sed -E 's/^"ref": *"//; s/"$//' || true)
            # Same first-field shape for the head object's "sha".
            DEP_HEAD_SHA=$(printf '%s' "${DEP_PR_JSON}" | tr -d '\n' \
                | grep -Po '"head": *\{[^{]*"sha": *"[^"]*"' \
                | grep -Po '"sha": *"[^"]*"$' \
                | sed -E 's/^"sha": *"//; s/"$//' || true)
        fi
        if [[ -z "${DEP_BASE_REF}" ]]; then
            echo "[$(date --utc +%FT%T.%3NZ)] WARNING: could not determine the base branch of ${DEP_REPO}#${DEP_PR} -- branch-mismatch guard inconclusive, building this dependency as requested" >&2
        elif [[ "$(branch_channel "${DEP_BASE_REF}")" != "$(branch_channel "${PULL_BASE_REF}")" ]]; then
            echo "[$(date --utc +%FT%T.%3NZ)] WARNING: ${DEP_REPO}#${DEP_PR} is based on branch '${DEP_BASE_REF}' but this job tests branch '${PULL_BASE_REF}' of ${REPO_OWNER}/${REPO_NAME} -- building it would test a combination that can never ship, so this dependency is SKIPPED and the job runs against the released ${DEP_REPO} instead; to actually test this dep here, point the Depends-On line at a PR based on '${PULL_BASE_REF}' (e.g. this change's cherry-pick)" >&2
            # Diagnostic only: a failed artifact write must never fail the job.
            echo "branch-mismatch ${DEP_REPO}#${DEP_PR} dep-base=${DEP_BASE_REF} job=${REPO_OWNER}/${REPO_NAME}@${PULL_BASE_REF} $(date --utc +%FT%T.%3NZ)" >> "${ARTIFACT_DIR}/depends-on-branch-mismatch.txt" \
                || echo "[$(date --utc +%FT%T.%3NZ)] WARNING: could not write ${ARTIFACT_DIR}/depends-on-branch-mismatch.txt" >&2
            MISMATCH_SKIPPED=true
            continue
        fi
    fi

    echo "[$(date --utc +%FT%T.%3NZ)] Fetching ${DEP_REPO}#${DEP_PR} once for $(printf '%s' "${MATCHED_CANDIDATES}" | grep -c .) matching candidate(s)"
    SRC_DIR=$(mktemp -d)
    TARBALL_FILE=$(mktemp)
    # Immutable SHA archive when the head commit is known (guard metadata
    # fetch), mutable PR-head URL otherwise (rehearsals skip the guard; a
    # metadata-fetch failure falls back here too, accepting the small
    # revision-mix race rather than failing the job over an optional pin).
    TARBALL_URL="https://github.com/${DEP_REPO}/archive/refs/pull/${DEP_PR}/head.tar.gz"
    if [[ -n "${DEP_HEAD_SHA:-}" ]]; then
        TARBALL_URL="https://github.com/${DEP_REPO}/archive/${DEP_HEAD_SHA}.tar.gz"
        echo "[$(date --utc +%FT%T.%3NZ)] Pinning ${DEP_REPO}#${DEP_PR} source to its current head commit ${DEP_HEAD_SHA} (immutable archive) -- both the image build and the e2e step's TESTS_SOURCE fetch use exactly this revision even if the PR is pushed to mid-run"
    fi
    # A Depends-On line explicitly requested this PR's source, so a failed
    # fetch fails the job LOUDLY (named repo/PR, retest hint, temp cleanup)
    # rather than degrading to this job's default pre-built images/tests:
    # silently running stale code after the author asked for the sibling
    # PR's code would surface as a confusing test failure a full cluster
    # run later, not as a fetch failure (the exact scenario TESTS_SOURCE
    # exists to fix). --retry absorbs transient CDN hiccups first,
    # mirroring the description fetch's retry pattern above; archive
    # downloads are CDN-backed and not subject to the anonymous
    # api.github.com rate limit that motivates that fetch's no-op
    # fallback, which does NOT apply here.
    if ! curl -sfL --retry 3 --retry-delay 5 "${TARBALL_URL}" -o "${TARBALL_FILE}"; then
        echo "[$(date --utc +%FT%T.%3NZ)] ERROR: could not fetch ${DEP_REPO}#${DEP_PR} source from ${TARBALL_URL} after retries -- a Depends-On line requested it, so refusing to continue with this job's default (pre-built) code; /retest once GitHub is reachable" >&2
        rm -rf "${SRC_DIR}"
        rm -f "${TARBALL_FILE}"
        exit 1
    fi
    tar xzf "${TARBALL_FILE}" -C "${SRC_DIR}" --strip-components=1
    rm -f "${TARBALL_FILE}"

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

        # TESTS_SOURCE sentinel: hand the depended-on PR's SOURCE to this
        # job's own e2e test step instead of building a container image from
        # it. For jobs whose e2e test container ships oadp-operator's test
        # code PRE-BUILT from a release branch (the KDM and velero-family
        # e2e configs run konveyor/oadp-operator-e2e-tests, whose
        # build/ci-Dockerfile bakes the branch's source -- Go toolchain and
        # all -- into the image): a Depends-On oadp-operator PR's TEST-CODE
        # changes would otherwise never execute in that job, since
        # MANAGER_IMAGE only swaps the operator's manager image, not the
        # tests. A one-line POINTER file (the PR's archive URL) is written
        # into ${SHARED_DIR} for the e2e step to read; the e2e step fetches
        # the tarball itself. The tarball itself must NOT go through
        # ${SHARED_DIR}: it is a ~1 MiB Kubernetes Secret (see the qe-agent/
        # quay/stackrox step docs) while this repo's source archives are
        # 10+ MB compressed. No Build, no ImageStream, and nothing is
        # appended to depends-on-images.txt -- the image-apply consumers
        # (oadp-apply-depends-on-images, the inline set-related-image steps)
        # must never see this sentinel. Dockerfile/context fields are
        # meaningless here and ignored.
        if [[ "${RELATED_ENV}" == "TESTS_SOURCE" ]]; then
            TESTS_PTR_DEST="${SHARED_DIR}/depends-on-tests-source-$(printf '%s' "${DEP_REPO}" | tr '/' '-').txt"
            if ! printf '%s\n' "${TARBALL_URL}" > "${TESTS_PTR_DEST}"; then
                echo "[$(date --utc +%FT%T.%3NZ)] Failed to write ${TESTS_PTR_DEST} -- is ${SHARED_DIR} writable and non-full?" >&2
                rm -rf "${SRC_DIR}"
                rm -f "${TARBALL_FILE}"
                exit 1
            fi
            echo "[$(date --utc +%FT%T.%3NZ)] ${DEP_REPO}#${DEP_PR} test-source pointer saved for this job's e2e step via TESTS_SOURCE -> ${TESTS_PTR_DEST} (archive URL; the e2e step fetches the tarball itself, since it is far too large for SHARED_DIR)"
            RESOLVED_ANY=true
            continue
        fi

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
    if [[ "${MISMATCH_SKIPPED}" == "true" ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] Depends-On line(s) found and matched, but every matched dependency was skipped by the branch-mismatch guard (see the WARNINGs above and depends-on-branch-mismatch.txt) -- this job tested against the released dependencies"
    else
        echo "[$(date --utc +%FT%T.%3NZ)] Depends-On line(s) found, but none matched a configured candidate for this job -- nothing to resolve"
    fi
fi
