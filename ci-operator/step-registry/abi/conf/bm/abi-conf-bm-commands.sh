#!/bin/bash
# abi-conf-bm — Agent-based installer configuration (bare metal; **conf** phase).
#
# Logic in this Step:
# - Bare-minimum `install-config.yaml` scaffold -> OCP-version-aware defaults -> `baremetal` platform -> `agent-config.yaml` template.
# - `UpdateCfg Day0` merges, updates, or replaces config entries; `OCP__ABI__DAY0_SCRIPTS_YAML` scripts further customize `install-config.yaml` / `agent-config.yaml`.
# - Extracts BMC info to `ocp--bmc--info.json`; strips BMC credentials from `agent-config.yaml`.
# - Generates Cluster manifests.
# - `UpdateCfg Day1` + `OCP__ABI__DAY1_SCRIPTS_YAML` scripts customize manifests.
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


export OCP__ABI__CFG="${CLUSTER_PROFILE_DIR}/ocp--abi--cfg.yaml"; [ -r "${OCP__ABI__CFG}" ]

# Extract openshift-install from the release image.
oc adm release extract \
    -a "${CLUSTER_PROFILE_DIR}/pull-secret" \
    "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
    --command=openshift-install \
    --to="/tmp"
export PATH="/tmp:${PATH}"


function openshift-install () {
    typeset -i es=0
    {
        echo \
"$(date -Iseconds)|${FUNCNAME[0]@Q} ${*@Q}"$'\n'"$(printf '%.0s-' {1..80})"
        command openshift-install \
            --dir "${OCP__ABI__CLUSTER_DIR}/" \
            --log-level "${OCP__ABI__INSTLR_LOG_LEVEL}" \
            "$@" 2>&1 || es=$?
        echo "$(printf '%.0s=' {1..80})"
        ((! es))
    } | tee -a "${ARTIFACT_DIR}/ocp--installer--cluster.log"
    ((! PIPESTATUS[0]))
}

function UpdateCfg () {
    typeset topKey="${1:?}"; (($#)) && shift
    typeset cfgType='' cfgFile='' cfgCont='' updateOp=''
    while IFS=$'\t' read -r cfgType cfgFile cfgCont; do
        [[ "${cfgFile}" == */* ]] &&
            mkdir -p "${OCP__ABI__CLUSTER_DIR}/${cfgFile%/*}"
        true 1>> "${OCP__ABI__CLUSTER_DIR}/${cfgFile}"
        exec 3< <(cat "${OCP__ABI__CLUSTER_DIR}/${cfgFile}"); wait $!
        case ${cfgType} in
          (*+)  updateOp='select(fileIndex==0) *+ ' ;;
          (*-)  updateOp='select(fileIndex==0) * '  ;;
          (*=)  updateOp=''                         ;;
        esac
        updateOp+='select(fileIndex==1)'
        case ${cfgType} in
          (yaml+|yaml-|yaml=)
            yq eval-all "${updateOp}" \
                - \
                <(set +x; yq -p json -o yaml eval . 0<<<"${cfgCont}") \
                0<&3 1>"${OCP__ABI__CLUSTER_DIR}/${cfgFile}"
            ;;
          (json+|json-|json=)
            yq -p json -o json eval-all "${updateOp}" \
                - \
                <(set +x; echo "${cfgCont}") \
                0<&3 1>"${OCP__ABI__CLUSTER_DIR}/${cfgFile}"
            ;;
          (*)   : "Invalid Type: ${cfgType}"; false;;
        esac
        exec 3<&-
    done 0< <(
        yq -o json eval . "${OCP__ABI__CFG}" |
        jq -r --arg k "${topKey}" '
            (.[$k].configFileOverride // empty) | to_entries[] |
            .key as $type | .value[]? | to_entries[] |
            [$type, .key, (
                if ($type | startswith("json")) then .value
                else (.value | tojson)
                end
            )] | join("\t")
        '
    )
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
            .sshKey=$sshKey
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

# Enrich with OCP-version-aware defaults.
openshift-install create install-config
# Update for Bare Metal target.
yq -i eval \
    '.platform={"baremetal": {}}' \
    "${OCP__ABI__CLUSTER_DIR}/install-config.yaml"

# Create `agent-config.yaml` template.
openshift-install agent create agent-config-template
# Being idempotent on re-run.
[ -s "${OCP__ABI__CLUSTER_DIR}/agent-config.yaml" ] || {
    jq -r \
        '."*agentconfig.AgentConfig".File.Data' \
        "${OCP__ABI__CLUSTER_DIR}/.openshift_install_state.json" |
    base64 -d 1> "${OCP__ABI__CLUSTER_DIR}/agent-config.yaml"
}

# Customize `install-config.yaml` and complete `agent-config.yaml`.
UpdateCfg Day0
eval "$(BuildCustomScriptsFromYAML OCP__ABI__DAY0_SCRIPTS_YAML)"

# Retrieve BMC Information from `agent-config.yaml`.
#   Currently, if all Master Nodes are ready to be installed, but
#   not all Worker Nodes are registering, the
#   `wait-for bootstrap-complete` will exit out with error.
#   As workaround, we boot the Worker Nodes first, and the
#   Rendezvous Host last.
{
    yq -p yaml -o json eval . |
    jq \
        --rawfile usr <(set +x; cat "${CLUSTER_PROFILE_DIR}/cred--bmc--usr") \
        --rawfile pwd <(set +x; cat "${CLUSTER_PROFILE_DIR}/cred--bmc--pwd") \
        --argjson rIP "$(yq -o json '(select(
            (.rendezvousIP | length) > 0) | .rendezvousIP
        ) // ([
            (.hosts[] | select(.role == "master")),
            (.hosts[] | select(.role == "arbiter")),
            (.hosts[] | select((.role == "") or (.role == null)))
        ] | .[0] | [.networkConfig.interfaces[] |
            select(.ipv4.enabled == true) |
            .ipv4.address[0].ip
        ] | .[0]) // error(
            "rendezvousIP could not be determined"
        ) ' "${OCP__ABI__CLUSTER_DIR}/agent-config.yaml")" \
        '[(
            (.hosts[] | select(.role == "worker")),
            ((
                (.hosts[] | select((.role == "") or (.role == null))),
                (.hosts[] | select(.role == "auto-assign")),
                (.hosts[] | select(.role == "arbiter")),
                (.hosts[] | select(.role == "master"))
            ) | select(any((
                .networkConfig.interfaces[] |
                select(.ipv4.enabled == true) |
                .ipv4.address[]?.ip
            ); . == $rIP) | not)),
            (.hosts[] | select(any((
                .networkConfig.interfaces[] |
                select(.ipv4.enabled == true) |
                .ipv4.address[]?.ip
            ); . == $rIP)))
        ) | {
            url: ("https://" + (.bmc.address | split("://")[-1])),
            usr: (.bmc.username // ($usr | rtrimstr("\n"))),
            pwd: (.bmc.password // ($pwd | rtrimstr("\n"))),
            hostIPv4: ([
                .networkConfig.interfaces[] |
                select(.ipv4.enabled == true) |
                .ipv4.address[0]?.ip
            ][0] // null)
        }]'
} 0< "${OCP__ABI__CLUSTER_DIR}/agent-config.yaml" 1> "${SHARED_DIR}/ocp--bmc--info.json"

# Strip BMC Credentials from `agent-config.yaml`.
exec 3< <(cat "${OCP__ABI__CLUSTER_DIR}/agent-config.yaml"); wait $!
{
    yq -p yaml -o json eval . |
    jq '.hosts[].bmc |= del(.username, .password)' |
    yq -p json -o yaml eval .
} 0<&3 1> "${OCP__ABI__CLUSTER_DIR}/agent-config.yaml"
exec 3<&-

# Set ISO Mode.
((OCP__ABI__MIN_ISO)) && (
    export __IMG__ROOT_FS="${OCP__ABI__TUN_SVC__DP_BASE_URL%%/}/${OCP__ABI__TUN_SVC__DP_PORT}/boot-artifacts"
    yq -i eval '
        .minimalISO=true |
        .bootArtifactsBaseURL=strenv(__IMG__ROOT_FS)
    ' "${OCP__ABI__CLUSTER_DIR}/agent-config.yaml"
)

# Generate full manifest tree.
openshift-install agent create cluster-manifests

# Manifest Customization.
UpdateCfg Day1
eval "$(BuildCustomScriptsFromYAML OCP__ABI__DAY1_SCRIPTS_YAML)"

# Save OCP Installation information for next Step.
tar zcf "${SHARED_DIR}/ocpClusterInf.tgz" -C "${OCP__ABI__CLUSTER_DIR}/" .
