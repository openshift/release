#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset jobDescFile="${CLUSTER_PROFILE_DIR}/${JT__TRIG_JOB_LIST}"
typeset trigCondStep='' trigCondPars=''
typeset trigCondName=trigger-jobs-trig-time-eval
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
    typeset trigCondFlag='' datePars='' mathExpr=''
    : "$(printf 'trigCondFlgs=0x%08x; JT__TRIG_COND_EXEC_FLGS=0x%08x' ${trigCondFlgs} "${JT__TRIG_COND_EXEC_FLGS}")"
    ((trigCondFlgs & JT__TRIG_COND_EXEC_FLGS)) || continue
    [ "${trigCondStep}" = "${trigCondName}" ] || continue
    IFS=$'\t' read -r trigCondFlag datePars mathExpr 0< <(jq -cr \
        --arg defVal "${trigCondName}" \
        '[
            .trigCondFlag//$defVal,
            (.datePars//[] | @json),
            (.mathExpr//[] | @json)
        ] | @tsv' \
    0<<<"${trigCondPars}")
    ####    Main Logic                                                      ####
    typeset -i timeVal=0
    {
        jq -en \
            --argjson datePars "${datePars}" \
            --argjson mathExpr "${mathExpr}" \
            '
                ($datePars | length) and
                ($datePars[0] | length) and
                ($mathExpr | length) and
                ($mathExpr[0] | length)
            ' ||
        false
    }
    timeVal="$(eval "date $(jq -r 'map(@sh) | join(" ")' <<<"${datePars}")")"
    (eval "let $(jq -r 'map(@sh) | join(" ")' <<<"${mathExpr}")") &&
        echo -n "${timeVal}" 1> "${SHARED_DIR}/${trigCondFlag}" ||              # Trigger Job.
        rm -rf "${SHARED_DIR:?}/${trigCondFlag}"                                # Skip Job.
    ############################################################################
done 0< <(jq -cr '
    .[] |
    .trigCond//[] |
    .[] |
    [.trigCondFlgs//0, .trigCondStep//"", (.trigCondPars//{} | @json)] |
    @tsv
' "${jobDescFile}")

true
