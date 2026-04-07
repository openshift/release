#!/bin/bash
# abi-bm-conf — Agent-based installer configuration (bare metal).
#
# Prepares **install-config** / **agent-config**, runs DAY0/DAY1 YAML hooks, builds **bmc--info.json**,
# strips **.bmc** credentials from **agent-config**, runs **`openshift-install agent create cluster-manifests`**,
# and writes **`${SHARED_DIR}/ocpClusterInf.tgz`** for **abi-bm-install**. Broader ABI context: **../../README.md**.
#
# **CLUSTER_PROFILE_DIR** must contain: **pull-secret**, **ssh-publickey**, **cred--bmc--usr**, **cred--bmc--pwd**.
#
# Step input parameters: **`abi-bm-conf-ref.yaml`** (`env` entries; step registry docs). Set via Job Conf. YAML **.tests[*].steps.env**.
#
# Logic in this Step:
# - **install-config** scaffold -> **agent-config** template -> **create install-config** -> DAY0 -> **bmc--info.json**.
# - (**usr** / **pwd** / **url**) -> strip **.bmc** -> **cluster-manifests** -> DAY1 -> **`${SHARED_DIR}/ocpClusterInf.tgz`**. **`agent create image`** is in **abi-bm-install**.
#
set -euxo pipefail
shopt -s inherit_errexit

mkdir -p "${OCP__ABI__CLUSTER_DIR}"

eval "$(
    curl -fsSL "https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/main/libs/bash/common/BuildCustomScriptsFromYAML.sh"
)"

eval "$(
    curl -fsSL "https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/main/libs/bash/common/EnsureReqs.sh"
)"
EnsureReqs yq

function openshift-install () {
    command openshift-install \
        --dir "${OCP__ABI__CLUSTER_DIR}/" \
        --log-level "${OCP__ABI__INSTLR_LOG_LEVEL}" \
        "$@"
    true
}

# Create bare-minimum `install-config.yaml`.
{
    yq -p yaml -o json eval . |
    jq -c \
        --arg clsName "${OCP__ABI__BM__CLS_NAME}" \
        --arg baseDom "${OCP__ABI__BM__BASE_DOM}" \
        --rawfile pullCrd <(set +x; cat "${CLUSTER_PROFILE_DIR}/pull-secret") \
        --rawfile sshKey <(set +x; cat "${CLUSTER_PROFILE_DIR}/ssh-publickey") \
        '
            .baseDomain=$baseDom |
            .metadata.name=$clsName |
            .pullSecret=($pullCrd | rtrimstr("\n")) |
            .sshKey=($sshKey | rtrimstr("\n"))
        ' |
    yq -p json -o yaml eval .
} 0<<'fileEOF' 1> "${OCP__ABI__CLUSTER_DIR}/install-config.yaml"
apiVersion: v1
baseDomain: ''
metadata:
  name: ''
platform: {none: {}}
pullSecret: ''
sshKey: ''
fileEOF

# Create `agent-config.yaml` template.
openshift-install agent create agent-config-template

# Update `install-config.yaml` with OCP-version-aware defaults.
openshift-install create install-config

# Customize `install-config.yaml` and complete `agent-config.yaml`.
eval "$(BuildCustomScriptsFromYAML OCP__ABI__DAY0_SCRIPTS_YAML)"

# Retrieve BMC information from **agent-config.yaml** → **bmc--info.json** (per-host **usr** / **pwd** when set; **cred--bmc--\*** is a shared fallback).
{
    yq -p yaml -o json eval . |
    jq \
        --rawfile usr <(set +x; cat "${CLUSTER_PROFILE_DIR}/cred--bmc--usr") \
        --rawfile pwd <(set +x; cat "${CLUSTER_PROFILE_DIR}/cred--bmc--pwd") \
        '[
            .hosts[].bmc |
            {
                url: ("https://" + (.address | split("://")[-1])),
                usr: (.username // ($usr | rtrimstr("\n"))),
                pwd: (.password // ($pwd | rtrimstr("\n")))
            }
        ]'
} 0< "${OCP__ABI__CLUSTER_DIR}/agent-config.yaml" 1> "${OCP__ABI__CLUSTER_DIR}/bmc--info.json"

# Strip **.bmc** credentials (**username** / **password**) from **`agent-config.yaml`** (well-formed ABI config).
exec 3< <(cat "${OCP__ABI__CLUSTER_DIR}/agent-config.yaml"); wait $!
{
    yq -p yaml -o json eval . |
    jq '.hosts[].bmc |= del(.username, .password)' |
    yq -p json -o yaml eval .
} 0<&3 1> "${OCP__ABI__CLUSTER_DIR}/agent-config.yaml"
exec 3<&-

# Generate full manifest tree.
openshift-install agent create cluster-manifests

# Customize manifests.
eval "$(BuildCustomScriptsFromYAML OCP__ABI__DAY1_SCRIPTS_YAML)"

# Save OCP Installation information for next Step.
tar zcf "${SHARED_DIR}/ocpClusterInf.tgz" -C "${OCP__ABI__CLUSTER_DIR}/" .
