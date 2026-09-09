#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset jobDescFile="${CLUSTER_PROFILE_DIR}/${JT__TRIG_JOB_LIST}"
typeset trigCondStep='' trigCondPars=''
typeset trigCondName=trigger-jobs-trig-check-resource-owner
typeset -i trigCondFlgs=0

#   Ensure Requirements.
PATH="$(exec 3>&1 1>&2
    typeset binDir="/tmp/bin"
    mkdir -p "${binDir}"
    jq --version || {
        wget -qO "${binDir}/jq" \
            "https://github.com/jqlang/jq/releases/latest/download/jq-$(
                uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/'
            )-$(
                uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'
            )" &&
        chmod a+x "${binDir}/jq"
        "${binDir}/jq" --version
    }
echo "${binDir}" 1>&3):${PATH}"

: "INPUT:"
jq -c '.[]' "${jobDescFile}"

while IFS=$'\t' read -r trigCondFlgs trigCondStep trigCondPars; do
    : "Processing: ${trigCondFlgs@Q} ${trigCondStep@Q} ${trigCondPars@Q}"
    typeset trigCondFlag='' expOwnerName=''
    : "$(printf 'trigCondFlgs=0x%08x; JT__TRIG_COND_EXEC_FLGS=0x%08x' ${trigCondFlgs} "${JT__TRIG_COND_EXEC_FLGS}")"
    ((trigCondFlgs & JT__TRIG_COND_EXEC_FLGS)) || continue
    [ "${trigCondStep}" = "${trigCondName}" ] || continue
    IFS=$'\t' read -r trigCondFlag expOwnerName 0< <(jq -cr \
        --arg defVal "${trigCondStep}" \
        '[.trigCondFlag//$defVal, .expOwnerName//""] | @tsv' \
    0<<<"${trigCondPars}")
    ####    Main Logic                                                      ####
    (( $(date +%V) % 2)) &&
        rm -rf "${SHARED_DIR:?}/${trigCondFlag}"     ||                         # Skip Job.
        echo -n "${expOwnerName}" 1> "${SHARED_DIR}/${trigCondFlag}"            # Trigger Job.
    ############################################################################
done 0< <(jq -cr '
    .[] |
    .trigCond//[] |
    .[] |
    [.trigCondFlgs//0, .trigCondStep//"", (.trigCondPars//{} | @json)] |
    @tsv
' "${jobDescFile}")

true
