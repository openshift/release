#!/bin/bash
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }

workdir=$(mktemp -d)
snapshot_tmp=""
trap 'rm -rf "${workdir}"; [[ -z "${snapshot_tmp}" ]] || rm -f "${snapshot_tmp}"' EXIT

get_json() {
    local url=$1 destination=$2 status attempt
    for attempt in 1 2 3; do
        status=$(curl -q --silent --show-error --proto '=https' --tlsv1.2 \
            --connect-timeout 10 --max-time 30 --max-filesize 2097152 \
            --output "${destination}" --write-out '%{http_code}' "${url}") || status=000
        if [[ "${status}" == 200 ]]; then
            jq -e . "${destination}" >/dev/null 2>&1 || fail "Invalid JSON from public metadata endpoint"
            return
        fi
        if [[ "${status}" != 000 && "${status}" != 429 && ! "${status}" =~ ^5[0-9][0-9]$ ]]; then
            fail "Public metadata request failed (HTTP ${status}); check public API access/rate limits. Redirects are not followed"
        fi
        echo "Public metadata request attempt ${attempt}/3 failed (HTTP ${status}); check rate limits or endpoint availability" >&2
        [[ ${attempt} == 3 ]] || sleep "$((attempt * 2))"
    done
    fail "Public metadata request exhausted bounded retries"
}

[[ "${HYPERSHIFT_PLATFORM}" == aws && "${AWS_MULTI_ARCH}" == false ]] || fail "PR release selection supports only AWS amd64"
[[ "${REPO_OWNER}" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,99}$ && "${REPO_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$ ]] || fail "Invalid repository identity"
[[ "${PULL_NUMBER}" =~ ^[1-9][0-9]{0,9}$ ]] || fail "Invalid PR number"
head_sha=$(jq -er --arg owner "${REPO_OWNER}" --arg repo "${REPO_NAME}" --argjson number "${PULL_NUMBER}" '
    select(.type == "presubmit" and .refs.org == $owner and .refs.repo == $repo and .refs.base_ref == "main")
    | .refs.pulls | select(length == 1 and .[0].number == $number) | .[0].sha' <<<"${JOB_SPEC}") || fail "JOB_SPEC is not the expected main PR"
[[ "${head_sha}" =~ ^[a-f0-9]{40}$ && "${PULL_PULL_SHA:-${head_sha}}" == "${head_sha}" ]] || fail "Invalid or conflicting PR head SHA"

get_json "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/pulls/${PULL_NUMBER}" "${workdir}/pr.json"
fetched_at=$(date -u +%FT%TZ)
jq -e --arg owner "${REPO_OWNER}" --arg repo "${REPO_NAME}" --arg sha "${head_sha}" --argjson number "${PULL_NUMBER}" '
    .number == $number and .base.repo.owner.login == $owner and .base.repo.name == $repo
    and .base.ref == "main" and .head.sha == $sha and (.body | type == "string")
    ' "${workdir}/pr.json" >/dev/null || fail "PR identity, head SHA, base main or body does not match this execution"

minor=$(jq -r .body "${workdir}/pr.json" | awk '
    function error(message) { print "ERROR: " message > "/dev/stderr"; failed = 1; exit 1 }
    {
        sub(/\r$/, ""); sub(/[ \t]+$/, "")
        if ($0 ~ /^ {0,3}(```+|~~~+)/) {
            marker = $0; sub(/^ */, "", marker)
            character = substr(marker, 1, 1); count = 0
            while (substr(marker, count + 1, 1) == character) count++
            if (!fenced) { fenced = character; fence_length = count; next }
            if (character == fenced && count >= fence_length && substr(marker, count + 1) ~ /^[ \t]*$/) { fenced = ""; next }
        }
        if (fenced) next
        if ($0 ~ /^ {0,3}#+[ \t]+/) {
            heading = $0; sub(/^ */, "", heading)
            depth = 0; while (substr(heading, depth + 1, 1) == "#") depth++
            sub(/^#+[ \t]+/, "", heading)
            if (depth == 2 && tolower(heading) ~ /^release test matrix/) {
                if (heading != "Release Test Matrix" || ++matrices != 1) error("Duplicate or ambiguous Release Test Matrix heading")
                matrix = 1; aws = 0; next
            }
            if (depth <= 2) { matrix = 0; aws = 0 }
            if (matrix && depth == 3) {
                aws = 0
                if (toupper(heading) ~ /^AWS([ \t]|$)/) {
                    if (heading != "AWS" || ++platforms != 1) error("Duplicate or ambiguous AWS heading")
                    aws = 1
                }
            }
            next
        }
        if (matrix && aws && $0 ~ /\[[ \t]*[xX]/) {
            if ($0 !~ /^[ \t]*[-*+][ \t]+\[[xX]\][ \t]+release-[1-9][0-9]*\.(0|[1-9][0-9]*)$/) error("Malformed checked AWS release entry")
            version = $0; sub(/^.*release-/, "", version)
            if (selected == "") selected = version
            else print "Ignoring additional checked AWS release-" version > "/dev/stderr"
        }
    }
    END {
        if (failed) exit 1
        if (fenced && matrix) error("Unclosed code fence in release matrix")
        if (matrices != 1 || platforms != 1 || selected == "") error("Require one Release Test Matrix, one AWS subsection and a checked release-X.Y")
        print selected
    }
') || fail "Cannot select a release from the PR matrix"
[[ "${minor}" =~ ^4\.(0|[1-9][0-9]*)$ ]] || fail "Only 4.x release streams are supported"

controller=https://amd64.ocp.releases.ci.openshift.org
get_json "${controller}/api/v1/releasestream/${minor}.0-0.ci/latest" "${workdir}/ci.json"
jq -e --arg minor "${minor}" '
    .phase == "Accepted" and (.name | startswith($minor + ".0-0.ci-"))
    and (.name | test("^[0-9]+\\.[0-9]+\\.0-0\\.ci-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$"))
    and (.pullSpec | type == "string")' "${workdir}/ci.json" >/dev/null || fail "No valid Accepted CI release for ${minor}"

get_json "${controller}/api/v1/releasestream/4-stable/tags" "${workdir}/stable-stream.json"
jq -e --arg minor "${minor}" '
    select(.name == "4-stable" and (.tags | type == "array")) | .tags
    | map(select(.phase == "Accepted" and (.name | startswith($minor + "."))
        and (.name | test("^[0-9]+\\.[0-9]+\\.(0|[1-9][0-9]*)$"))))
    | sort_by(.name | split(".") | map(tonumber)) | last | select(. != null)
    ' "${workdir}/stable-stream.json" > "${workdir}/stable.json" || fail "No Accepted GA stable release for ${minor}"

auth_args=()
if [[ -f /etc/ci-pull-credentials/.dockerconfigjson ]]; then
    auth_args=(--registry-config=/etc/ci-pull-credentials/.dockerconfigjson)
fi
pin_payload() {
    local metadata=$1 kind=$2 name pullspec repository digest pinned
    name=$(jq -er .name "${metadata}")
    pullspec=$(jq -er .pullSpec "${metadata}") || fail "Missing ${kind} pullspec"
    if [[ "${kind}" == ci ]]; then
        [[ "${pullspec}" =~ ^(registry\.ci\.openshift\.org/ocp/release|quay-proxy\.ci\.openshift\.org/openshift/ci):[A-Za-z0-9_.-]+$ ]] || fail "Invalid CI payload repository or tag"
    else
        [[ "${pullspec}" == "quay.io/openshift-release-dev/ocp-release:${name}-x86_64" ]] || fail "Stable payload is not the selected amd64 release"
    fi
    timeout 90s oc image info "${auth_args[@]}" --filter-by-os=linux/amd64 -o json "${pullspec}" > "${workdir}/${kind}-image.json" 2> "${workdir}/image-error" || fail "Cannot inspect ${kind} payload"
    digest=$(jq -er 'select(.config.architecture == "amd64" and .config.os == "linux") | .digest' "${workdir}/${kind}-image.json") || fail "Payload architecture must be linux/amd64"
    [[ "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]] || fail "Invalid payload digest"
    repository=${pullspec%:*}
    pinned="${repository}@${digest}"
    timeout 90s oc adm release info "${auth_args[@]}" -o json "${pinned}" > "${workdir}/${kind}-release.json" 2> "${workdir}/image-error" || fail "Cannot inspect immutable ${kind} release metadata"
    jq -e --arg name "${name}" '.metadata.version == $name' "${workdir}/${kind}-release.json" >/dev/null || fail "Payload version does not match ${kind} release name"
    jq -n --arg name "${name}" --arg pullspec "${pinned}" --arg digest "${digest}" '{name:$name,pullSpec:$pullspec,digest:$digest}' > "${workdir}/${kind}-resolved.json"
    printf '%s' "${pinned}"
}
ci_image=$(pin_payload "${workdir}/ci.json" ci)
stable_image=$(pin_payload "${workdir}/stable.json" stable)

snapshot_tmp=$(mktemp "${SHARED_DIR}/.pr-release-matrix.XXXXXX")
printf "export RELEASE_IMAGE_LATEST='%s'\nexport OCP_IMAGE_N1='%s'\nexport E2E_PREVIOUS_RELEASE_IMAGE='%s'\n" \
    "${ci_image}" "${stable_image}" "${stable_image}" > "${snapshot_tmp}"
chmod 600 "${snapshot_tmp}"
mkdir -p "${ARTIFACT_DIR}"
jq -n --arg platform aws --arg minor "${minor}" --arg headSHA "${head_sha}" \
    --arg fetchedAt "${fetched_at}" --slurpfile ci "${workdir}/ci-resolved.json" --slurpfile stable "${workdir}/stable-resolved.json" \
    '{platform:$platform,architecture:"amd64",minor:$minor,headSHA:$headSHA,fetchedAt:$fetchedAt,ci:$ci[0],stable:$stable[0]}' > "${ARTIFACT_DIR}/pr-release-matrix.json"
mv -f "${snapshot_tmp}" "${SHARED_DIR}/nodepool_release_images"
snapshot_tmp=""
echo "Selected AWS amd64 release-${minor}: CI $(jq -r .name "${workdir}/ci.json"), stable $(jq -r .name "${workdir}/stable.json")"
