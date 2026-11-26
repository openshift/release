#!/usr/bin/env bash

# The sourced proxy configuration can contain credentials.
set +x
set -Eeuo pipefail

export PATH=/usr/libexec/origin:$PATH

if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist, skipping community e2e image mirroring..."
    exit 0
fi
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
MIRROR_REPO="${MIRROR_REGISTRY_HOST}/${MIRROR_REGISTRY_PATH}"

# Grant anonymous image-pull access to the ephemeral CI namespace on the
# build farm so that 'openshift-tests images' can pull image-references from
# the per-job imagestream without registry credentials.
# Unset KUBECONFIG so this oc call targets the build farm, not the cluster
# under test.  This is the same pattern used by openshift-e2e-test-commands.sh.
echo "Granting anonymous image-pull access to CI namespace ${NAMESPACE} on the build farm..."
KUBECONFIG_BAK="${KUBECONFIG}"
unset KUBECONFIG
oc adm policy add-role-to-group \
    system:image-puller \
    system:unauthenticated \
    --namespace "${NAMESPACE}"
export KUBECONFIG="${KUBECONFIG_BAK}"

# Source the proxy configuration so extension binaries launched by
# 'openshift-tests images' can reach the private cluster API (needed to
# enumerate images). Extensions like ovn-kubernetes-tests-ext call the
# cluster API during image discovery; without the proxy they cannot resolve
# the internal API hostname.
if ! test -f "${SHARED_DIR}/proxy-conf.sh"; then
    echo "ERROR: proxy-conf.sh is missing; private cluster API access requires the generated proxy configuration." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "${SHARED_DIR}/proxy-conf.sh"

# Exempt only the CI registry and the registry serving this job's payload, so
# openshift-tests can pull extension binaries and image references directly.
# Broad CI-domain exemptions also match private test-cluster API hostnames.
# RELEASE_IMAGE_LATEST identifies the actual registry even when the build-farm
# API uses an in-cluster VIP; the API grant above runs before proxy sourcing.
if [[ ! "${RELEASE_IMAGE_LATEST:-}" =~ ^([a-zA-Z0-9.-]+(:[0-9]+)?)/[^[:space:]]+$ ]]; then
    echo "ERROR: RELEASE_IMAGE_LATEST must be a fully qualified image pullspec to scope registry proxy bypass." >&2
    exit 1
fi
payload_registry="${BASH_REMATCH[1]}"
NO_PROXY="${NO_PROXY:+${NO_PROXY},}registry.ci.openshift.org,${payload_registry}"
no_proxy="${no_proxy:+${no_proxy},}registry.ci.openshift.org,${payload_registry}"
export NO_PROXY no_proxy

# Report presence, never values: proxy URLs and even client errors can contain
# credentials. Go clients prefer the nonempty uppercase variable.
for proxy_variable in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy; do
    if [[ -n "${!proxy_variable:-}" ]]; then
        echo "${proxy_variable}: set (nonempty)"
    else
        echo "${proxy_variable}: unset or empty"
    fi
done
if [[ -n "${NO_PROXY:-}" && -n "${no_proxy:-}" && "${NO_PROXY}" != "${no_proxy}" ]]; then
    echo "NO_PROXY and no_proxy differ; Go clients prefer NO_PROXY."
fi

api_server=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubeconfig_proxy=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.proxy-url}')

# Match DNS names as Go's proxy selector does, including optional ports and
# domain suffixes. CIDRs match literal IPs only, not resolved DNS addresses.
api_matches_no_proxy() {
    local entry entry_port
    local -a entries
    IFS=',' read -r -d '' -a entries < <(printf '%s\0' "${NO_PROXY:-${no_proxy:-}}")
    for entry in "${entries[@]}"; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        entry="${entry,,}"
        [[ "${entry}" == "*" ]] && return 0
        [[ -z "${entry}" || "${entry}" == */* ]] && continue
        if [[ "${entry}" == *:* ]]; then
            entry_port="${entry##*:}"
            [[ -z "${entry_port}" || "${entry_port}" == "${api_port}" ]] || continue
            entry="${entry%:*}"
        fi
        if [[ "${entry}" == \*.* ]]; then
            entry="${entry#\*}"
        fi
        if [[ "${entry}" == .* ]]; then
            [[ "${api_host}" == *"${entry}" ]] && return 0
        elif [[ "${api_host}" == "${entry}" || "${api_host}" == *".${entry}" ]]; then
            return 0
        fi
    done
    return 1
}

if [[ "${api_server}" =~ ^https://([a-zA-Z0-9.-]+)(:([0-9]+))?/?$ ]]; then
    api_host="${BASH_REMATCH[1],,}"
    api_port="${BASH_REMATCH[3]:-443}"
    echo "Cluster API hostname: ${api_host}; port: ${api_port}"
    if [[ "${api_host}" =~ ^[0-9.]+$ ]]; then
        echo "NO_PROXY matching not evaluated for a literal API IP address."
    elif api_matches_no_proxy; then
        echo "API hostname matches effective NO_PROXY: yes (environment bypass rule)."
    else
        echo "API hostname matches effective NO_PROXY: no."
    fi
else
    echo "NO_PROXY matching not evaluated: API URL is not an HTTPS DNS endpoint."
fi
if [[ -n "${kubeconfig_proxy}" ]]; then
    echo "Kubeconfig proxy-url: set; it overrides environment proxy selection."
else
    echo "Kubeconfig proxy-url: unset."
fi

# Use the same Go client stack and node-list operation needed by extensions.
# Bound the whole process as well as individual requests. Do not print raw
# errors: net/http errors may include a proxy URL with user information.
probe_api() {
    local label=$1 output status reason
    if output=$(timeout --signal=TERM --kill-after=5s 30s \
        oc --request-timeout=20s get --raw='/api/v1/nodes?limit=1' 2>&1 >/dev/null); then
        echo "API node-list probe (${label}): succeeded."
        return 0
    else
        status=$?
    fi
    case "${output}" in
        *"proxyconnect tcp:"*"lookup "*) reason="proxy CONNECT failure (DNS lookup failure)" ;;
        *"proxyconnect tcp:"*) reason="proxy CONNECT failure" ;;
        *"lookup "*"no such host"*) reason="DNS name not found" ;;
        *"lookup "*) reason="DNS lookup failure" ;;
        *"x509:"*|*"tls:"*) reason="TLS verification or handshake failure" ;;
        *"Unauthorized"*|*"Forbidden"*) reason="API authentication or authorization failure" ;;
        *"connection refused"*) reason="connection refused" ;;
        *"timeout"*|*"deadline exceeded"*) reason="request timed out" ;;
        *) reason="unclassified error (raw output withheld to protect credentials)" ;;
    esac
    if [[ "${status}" == 124 || "${status}" == 137 ]]; then
        reason="process timeout"
    fi
    echo "API node-list probe (${label}): failed (exit ${status}; ${reason})."
    return "${status}"
}

normal_api_status=0
probe_api normal-environment || normal_api_status=$?
if [[ -n "${kubeconfig_proxy}" ]]; then
    echo "Forced environment-proxy probe skipped: kubeconfig already selects an explicit proxy."
elif [[ -n "${HTTPS_PROXY:-${https_proxy:-}}" ]]; then
    (
        # Change only this probe, not the environment used for image discovery.
        export HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-}}" NO_PROXY="" no_proxy=""
        probe_api forced-https-proxy
    ) || true
else
    echo "Forced environment-proxy probe skipped: neither HTTPS_PROXY nor https_proxy is configured."
fi
if (( normal_api_status != 0 )); then
    echo "ERROR: cluster API node listing failed in the image-discovery environment; see proxy diagnostics above." >&2
    exit "${normal_api_status}"
fi

echo "Discovering community e2e test images required by this release via 'openshift-tests images'..."
openshift-tests images --to-repository "${MIRROR_REPO}" | grep "${MIRROR_REPO}" >> "${SHARED_DIR}/mirror-images-list.yaml"

# `openshift-tests images` does not include the current registry.k8s.io/pause
# tags in its output (their layers aren't compressed, which quay.io's mirror
# path used to compute the tool's output doesn't support). Since pause is the
# pod sandbox/infra container used by virtually every pod, missing it breaks
# almost every test in a disconnected cluster. Mirror the known versions
# explicitly as a workaround, matching the same fallback used by
# openstack-test-e2e-images.
#
# Also push each version under its own plain tag (in addition to the e2e-*
# destination tags openshift-tests' --from-repository rewriting expects):
# the generated ImageTagMirrorSet below maps source: registry.k8s.io/pause to
# this repo tag-for-tag, so *any* direct pull of registry.k8s.io/pause:<tag>
# (not just ones openshift-tests rewrote) gets redirected to
# ${MIRROR_REPO}:<tag> — which must therefore also exist.
cat <<EOF >> "${SHARED_DIR}/mirror-images-list.yaml"
registry.k8s.io/pause:3.9 ${MIRROR_REPO}:e2e-27-registry-k8s-io-pause-3-9-p9APyPDU5GsW02Rk
registry.k8s.io/pause:3.9 ${MIRROR_REPO}:e2e-28-registry-k8s-io-pause-3-9-p9APyPDU5GsW02Rk
registry.k8s.io/pause:3.9 ${MIRROR_REPO}:3.9
registry.k8s.io/pause:3.10 ${MIRROR_REPO}:e2e-25-registry-k8s-io-pause-3-10-b3MYAwZ_MelO9baY
registry.k8s.io/pause:3.10 ${MIRROR_REPO}:e2e-27-registry-k8s-io-pause-3-10-b3MYAwZ_MelO9baY
registry.k8s.io/pause:3.10 ${MIRROR_REPO}:3.10
registry.k8s.io/pause:3.10.1 ${MIRROR_REPO}:e2e-22-registry-k8s-io-pause-3-10-1-a6__nK-VRxiifU0Z
registry.k8s.io/pause:3.10.1 ${MIRROR_REPO}:e2e-25-registry-k8s-io-pause-3-10-1-a6__nK-VRxiifU0Z
registry.k8s.io/pause:3.10.1 ${MIRROR_REPO}:3.10.1
registry.k8s.io/pause:3.10.2 ${MIRROR_REPO}:e2e-22-registry-k8s-io-pause-3-10-2-Xnr_kb1i4Z5Tu7vt
registry.k8s.io/pause:3.10.2 ${MIRROR_REPO}:3.10.2
EOF

# The ovn-kubernetes-tests-ext test extension (owns the
# [Feature:NetworkSegmentation] user-defined-network tests) reports null
# images to 'openshift-tests images' (confirmed via that command's own log:
# `Extension "ovn-kubernetes-tests-ext" reported null images, treating as
# empty`), so any image it needs that isn't already covered by k8s-tests-ext
# is silently missing from discovery. This broke every UDN test in a
# disconnected run (~29 failures) on ImagePullBackOff for agnhost:2.63.0.
# The image is still published under the same deterministic tag in
# quay.io/openshift/community-e2e-images (confirmed via the failing pod's
# requested destination tag, which openshift-tests computes independently of
# what we mirror), so mirror it explicitly as a fallback, same pattern as
# the pause workaround above. If future releases bump the ovn-kubernetes
# agnhost version again, this will need updating the same way.
cat <<EOF >> "${SHARED_DIR}/mirror-images-list.yaml"
quay.io/openshift/community-e2e-images:e2e-2-registry-k8s-io-e2e-test-images-agnhost-2-63-0-t_yPbigw-dJBrfQ9 ${MIRROR_REPO}:e2e-2-registry-k8s-io-e2e-test-images-agnhost-2-63-0-t_yPbigw-dJBrfQ9
EOF

if [[ -n "${EXTRA_MIRROR_IMAGES}" ]]; then
    echo "Appending EXTRA_MIRROR_IMAGES entries:"
    echo "${EXTRA_MIRROR_IMAGES}"
    echo "${EXTRA_MIRROR_IMAGES}" >> "${SHARED_DIR}/mirror-images-list.yaml"
fi

echo "${MIRROR_REPO}" > "${SHARED_DIR}/mirror-tests-image"
echo "Generated list of images to mirror on ${MIRROR_REPO}:"
cat "${SHARED_DIR}/mirror-images-list.yaml"

cat <<EOF > /tmp/idms.yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: mirror-e2e-tests
spec:
  imageDigestMirrors:
EOF
cat <<EOF > /tmp/itms.yaml
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: mirror-e2e-tests
spec:
  imageTagMirrors:
EOF
SOURCE_IMAGES=$(awk '{print $1}' "${SHARED_DIR}/mirror-images-list.yaml" | sed -E 's/@[^[:space:]]+$//; s#:[^:/]+$##' | sort -u)
for SOURCE_IMAGE in $SOURCE_IMAGES; do
    cat <<EOF >> /tmp/idms.yaml
  - mirrors:
    - ${MIRROR_REPO}
    source: ${SOURCE_IMAGE}
EOF
    cat <<EOF >> /tmp/itms.yaml
  - mirrors:
    - ${MIRROR_REPO}
    source: ${SOURCE_IMAGE}
EOF
done
echo "Generated ImageDigestMirrorSet and ImageTagMirrorSet:"
cat /tmp/idms.yaml
cat /tmp/itms.yaml

echo "Applying ImageDigestMirrorSet and ImageTagMirrorSet..."
oc apply -f /tmp/idms.yaml
oc apply -f /tmp/itms.yaml

echo "Done"
