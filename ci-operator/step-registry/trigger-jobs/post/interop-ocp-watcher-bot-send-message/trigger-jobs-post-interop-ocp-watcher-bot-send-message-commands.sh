#!/bin/bash
# shellcheck disable=SC2034 # False pos. due to the way the var. is used.
set -euxo pipefail; shopt -s inherit_errexit

typeset postTaskStep='' postTaskPars=''
typeset postTaskName=trigger-jobs-post-interop-ocp-watcher-bot-send-message
typeset -i dryRun=0 postTaskFlgs=0

typeset jobList=''
typeset secretDir; secretDir="/tmp/bot_secrets"
typeset botJobList; botJobList="/tmp/job-list"
typeset -a botJobArr=()

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

[[ "${JOB_NAME}" == 'rehearse-'* ]] && dryRun=1

while IFS=$'\t' read -r postTaskFlgs postTaskStep postTaskPars jobList; do
    typeset postTaskFlag=''
    : "postTaskFlgs=${postTaskFlgs}; JT__POST_TASK_EXEC_FLGS=${JT__POST_TASK_EXEC_FLGS}"
    ((postTaskFlgs & JT__POST_TASK_EXEC_FLGS)) || continue
    [ "${postTaskStep}" = "${postTaskName}" ] || continue
    IFS=$'\t' read -r postTaskFlag 0< <(jq -cr \
        --arg defVal "${postTaskStep}" \
        '.postTaskFlag//$defVal' \
    0<<<"${postTaskPars}")
    [ -f "${SHARED_DIR}/${postTaskFlag}" ] || {
        : 'Skipping Job.'
        continue
    }
    ####    Main Logic                                                      ####
    # Collect Job list for bulk notification.
    botJobArr+=("$(jq -cr '.[] | {jobName, active}' 0<<<"${jobList}")")
    ############################################################################
done 0< <(jq -cr '
    .[] | ( # Backward compatibility: convert old list format to new one.
        if has("job_name") then
            {
                jobList: [{jobName: .job_name, active: .active}],
                postTask: [{
                    postTaskFlgs: 1,
                    postTaskStep: "trigger-jobs-post-interop-ocp-watcher-bot-send-message",
                    postTaskPars: {postTaskFlag: "trigger-jobs-post-interop-ocp-watcher-bot-send-message"}
                }]
            }
        else
            .
        end
    ) as $parent |
    $parent.postTask//[] |
    .[] |
    [.postTaskFlgs//0, .postTaskStep//"", (.postTaskPars//{} | @json), ($parent.jobList//[] | @json)] |
    @tsv
' "${CLUSTER_PROFILE_DIR}/${JT__TRIG_JOB_LIST}")

((${#botJobArr[@]})) && {
    printf '%s\n' "${botJobArr[@]}" | jq -cs '.' 1> "${botJobList}"

    echo "Executing interop-ocp-watcher-bot..."
        eval "$(cat - 0<<cmd1EOF
$( ((dryRun)) && echo echo || echo eval ) $(printf '%q' "$(cat - 0<<cmd2EOF
    interop-ocp-watcher-bot \
        --job_file_path=${botJobList@Q} \
        --mentioned_group_id=$(printf '%q' "$(cat "${secretDir}/${JT__POST__WB__MENTIONED_GROUP_ID_SECRET_NAME}")") \
        --webhook_url=$(printf '%q' "$(cat "${secretDir}/${JT__POST__WB__WEBHOOK_URL_SECRET_NAME}")") \
        --job_group_name=${JT__POST__WB__JOB_GROUP_NAME@Q}
cmd2EOF
)")
cmd1EOF
        )"
}

true
