#!/usr/bin/env bash

set -euo pipefail

stage_registry="${KMM_STAGE_REGISTRY:-registry.stage.redhat.io}"
mirror_name="${KMM_IMAGE_MIRROR_NAME:-kmm-stage-registry}"
ca_configmap_name="${KMM_STAGE_CA_CONFIGMAP_NAME:-kmm-stage-registry-ca}"
pull_credentials_path="${KMM_PULL_CREDENTIALS_PATH:-/var/run/secrets/ci-pull-credentials/.dockerconfigjson}"
pull_secret_workdir="/tmp/kmm-stage-registry-credentials"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

stage_ca="${tmp_dir}/stage-registry-ca.pem"

echo "Retrieving the CA presented by ${stage_registry}..."
if ! openssl s_client \
    -showcerts \
    -connect "${stage_registry}:443" \
    -servername "${stage_registry}" \
    </dev/null 2>/dev/null | openssl x509 -outform PEM > "${stage_ca}"; then
    echo "Failed to retrieve the CA certificate from ${stage_registry}" >&2
    exit 1
fi
if [[ ! -s "${stage_ca}" ]]; then
    echo "The CA certificate retrieved from ${stage_registry} is empty" >&2
    exit 1
fi

if [[ ! -f "${pull_credentials_path}" ]]; then
    echo "CI pull credentials not found at ${pull_credentials_path}" >&2
    exit 1
fi
if ! jq -e . "${pull_credentials_path}" >/dev/null; then
    echo "CI pull credentials are not valid JSON" >&2
    exit 1
fi

mkdir -p "${pull_secret_workdir}"
echo "Extracting the cluster pull secret..."
oc extract secret/pull-secret -n openshift-config --confirm --to "${pull_secret_workdir}"
cluster_pull_secret="${pull_secret_workdir}/.dockerconfigjson"
if [[ ! -f "${cluster_pull_secret}" ]] || ! jq -e . "${cluster_pull_secret}" >/dev/null; then
    echo "The extracted cluster pull secret is missing or invalid" >&2
    exit 1
fi

# The ci-pull-credentials bundle contains the stage registry auth in Docker
# config format. Do not print it: this step's logs are retained as artifacts.
if ! stage_registry_auth=$(jq -er --arg registry "${stage_registry}" \
    '.auths[$registry].auth | strings | select(length > 0)' "${pull_credentials_path}"); then
    echo "No credentials for ${stage_registry} were found in ci-pull-credentials" >&2
    exit 1
fi

current_stage_registry_auth=""
if current_stage_registry_auth=$(jq -er --arg registry "${stage_registry}" \
    '.auths[$registry].auth | strings | select(length > 0)' "${cluster_pull_secret}"); then
    :
fi

if [[ "${current_stage_registry_auth}" == "${stage_registry_auth}" ]]; then
    echo "The cluster pull secret already contains credentials for ${stage_registry}; no update is needed."
else
    echo "Merging ${stage_registry} credentials from ci-pull-credentials into the cluster pull secret..."
    jq --arg registry "${stage_registry}" --arg auth "${stage_registry_auth}" \
        '.auths //= {} | .auths[$registry].auth = $auth' \
        "${cluster_pull_secret}" > "${pull_secret_workdir}/new-dockerconfigjson"
    if ! jq -e --arg registry "${stage_registry}" \
        '.auths[$registry].auth | strings | select(length > 0)' \
        "${pull_secret_workdir}/new-dockerconfigjson" >/dev/null; then
        echo "Failed to merge ${stage_registry} credentials into the cluster pull secret" >&2
        exit 1
    fi

    echo "Updating the cluster pull secret..."
    oc set data secret/pull-secret -n openshift-config \
        --from-file=.dockerconfigjson="${pull_secret_workdir}/new-dockerconfigjson"

    echo "Waiting for MachineConfigPools to finish applying the pull-secret update..."
    if ! oc wait mcp --all --for=condition=Updated=True --timeout=8m; then
        echo "MachineConfigPool rollout did not complete after the pull-secret update" >&2
        oc get mcp -o yaml || true
        exit 1
    fi
fi

existing_ca_configmap="$(oc get image.config.openshift.io/cluster -o jsonpath='{.spec.additionalTrustedCA.name}')"
if [[ -n "${existing_ca_configmap}" ]]; then
    echo "Adding ${stage_registry} to existing trusted CA ConfigMap ${existing_ca_configmap}"
    oc get configmap "${existing_ca_configmap}" -n openshift-config >/dev/null
    oc set data configmap/"${existing_ca_configmap}" \
        -n openshift-config \
        --from-file="${stage_registry}=${stage_ca}" \
        --from-file="${stage_registry}..443=${stage_ca}"
else
    echo "Creating trusted CA ConfigMap ${ca_configmap_name}"
    oc create configmap "${ca_configmap_name}" \
        -n openshift-config \
        --from-file="${stage_registry}=${stage_ca}" \
        --from-file="${stage_registry}..443=${stage_ca}" \
        --dry-run=client -o yaml | oc apply -f -
    oc patch image.config.openshift.io/cluster --type=merge \
        -p "{\"spec\":{\"additionalTrustedCA\":{\"name\":\"${ca_configmap_name}\"}}}"
fi

echo "Applying the KMM image mirror from registry.redhat.io/kmm to ${stage_registry}/kmm..."
if oc api-resources --api-group=config.openshift.io --no-headers \
    | awk '$1 == "imagedigestmirrorsets" { found=1 } END { exit found ? 0 : 1 }'; then
    oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ${mirror_name}
spec:
  imageDigestMirrors:
  - source: registry.redhat.io/kmm
    mirrors:
    - ${stage_registry}/kmm
    mirrorSourcePolicy: AllowContactingSource
EOF
else
    oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: ${mirror_name}
spec:
  repositoryDigestMirrors:
  - source: registry.redhat.io/kmm
    mirrors:
    - ${stage_registry}/kmm
EOF
fi

echo "Stage registry trust and KMM image mirroring configured."
