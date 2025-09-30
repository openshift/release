#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail




TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-7200}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
RC_HOST_AMD64="${RC_HOST_AMD64:-https://amd64.ocp.releases.ci.openshift.org}"
RC_STREAM="4-stable"

url="${RC_HOST_AMD64}/api/v1/releasestream/${RC_STREAM}/latest"
echo ${url}


latest_rc_from_release_controller(){
    local rc url

    rc="$(curl -fsSL "${RC_HOST_AMD64}/api/v1/releasestream/${RC_STREAM}/latest"  \
        | jq -r '.name' )"
    [[ -n "$rc" ]] && { echo "$rc"; return 0; }
    return 1
}


latest_release_image(){

    local rc

    rc="$(curl -fsSL "${RC_HOST_AMD64}/api/v1/releasestream/${RC_STREAM}/latest"  \
        | jq -r '.pullSpec' )"
    [[ -n "$rc" ]] && { echo "$rc"; return 0; }
    return 1
}

echo "Resolving latest RC's from release Controller (stream=${RC_STREAM})..."
TARGET_VERSION="$(latest_rc_from_release_controller)"

echo "Target version: ${TARGET_VERSION}"
TARGET_CHANNEL=${TARGET_CHANNEL:-candidate-4.20}
echo "TARGET channel: ${TARGET_CHANNEL}"

TARGET_IMAGE="$(latest_release_image)"
echo "Release_image: ${TARGET_IMAGE}"
DIGEST=$(oc adm release info "$TARGET_IMAGE" -o json | jq -r .digest)


#==========================================

HUB_KUBECONFIG="${SHARED_DIR}/kubeconfig"
SPOKE_KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
need jq

[[ -f "${HUB_KUBECONFIG}" ]] || { echo "Hub kubeconfig not found:${HUB_KUBECONFIG}" >&2; exit 1; }
[[ -f "${SPOKE_KUBECONFIG}" ]] || { echo "Spoke kubeconfig not found:${SPOKE_KUBECONFIG}" >&2; exit 1; }

now() { date +%s; }

upgrade_cluster() {
   

    local kfcg="$1" ctx="$2"

    echo "Upgrading ${ctx} to channel=${TARGET_CHANNEL} and upgrading to ${TARGET_VERSION} and Target image:${TARGET_IMAGE}"
    oc --kubeconfig="${kfcg}" patch clusterversion version --type merge -p "{\"spec\":{\"channel\":\"${TARGET_CHANNEL}\"}}"
    repo="${TARGET_IMAGE%:*}"
    echo "${repo}"
    oc --kubeconfig="${kfcg}" adm upgrade --to-image="${repo}@${DIGEST}" --allow-explicit-upgrade --allow-upgrade-with-warnings --force

}


wait_for_completed() {
    local kfcg="$1" ctx="$2" target="$3" start;
    start=$(now)
    echo "waiting for ${ctx} to complete upgrade to ${target}"
    while true; do
      local js state ver
      js="$(oc --kubeconfig="${kfcg}" get clusterversion version -o json 2>/dev/null || true)"
      state="$(jq -r '.status.history[0].state // empty' <<<"$js")"
      ver="$(jq -r '.status.history[0].version // empty' <<<"$js")"
      if [[ "$state" == "Completed" && "$ver" == "$target" ]]; then
        echo "${ctx}: Completed && ${ver}"
        break
      fi
      if (( $(now) - start > TIMEOUT_SECONDS )); then
        echo "Timeout waiting for ${ctx} (state='${state:-?}' version='${ver:-?}' target='${target}')" >&2
        exit 2
      fi
      echo " ${ctx}: state='${state:-?}', version='${ver:-?}', retry in ${POLL_INTERVAL}s"
      sleep "${POLL_INTERVAL}"
    done
}


echo "Target channel: ${TARGET_CHANNEL}"
echo "TARGET version: ${TARGET_VERSION}"

#hub upgrade
upgrade_cluster "${HUB_KUBECONFIG}" "hub"
wait_for_completed "${HUB_KUBECONFIG}" "hub" "${TARGET_VERSION}"

#spoke upgrade
# upgrade_cluster "${SPOKE_KUBECONFIG}" "spoke"
# wait_for_completed "${SPOKE_KUBECONFIG}" "spoke" "${TARGET_VERSION}"

echo "All selected clusters are at latest RCs"