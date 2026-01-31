#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset trigCondStep= trigCondPars=
typeset trigCondName="${HOSTNAME#${JOB_NAME_SAFE}-}"
typeset -i trigCondFlgs=0

while IFS=$'\t' read -r trigCondFlgs trigCondStep trigCondPars; do
    typeset trigCondFlag= expOwnerName=
    ((trigCondFlgs && JT__TRIG_COND_EXEC_FLGS)) || continue
    [ "${trigCondStep}" = "${trigCondName}" ] || continue
    IFS=$'\t' read -r trigCondFlag expOwnerName 0< <(
        echo "${trigCondPars}" |
        jq -cr \
            --arg defVal "${trigCondName}" \
            '[.trigCondFlag//$defVal, .expOwnerName//""] | @tsv'
    )
    ####    Main Logic                                                      ####
    (( $(date +%V) % 2)) &&
        rm -rf "${SHARED_DIR}/${trigCondFlag}"     ||                           # Skip Job.
        echo -n "${expOwnerName}" 1> "${SHARED_DIR}/${trigCondFlag}"            # Trigger Job.
    ############################################################################
done 0< <(jq -cr '
    .[] |
    .trigCond//[] |
    .[] |
    [.trigCondFlgs//0, .trigCondStep//"", (.trigCondPars//{} | @json)] |
    @tsv
' "${CLUSTER_PROFILE_DIR}/${JT__TRIG_JOB_LIST}")

true
