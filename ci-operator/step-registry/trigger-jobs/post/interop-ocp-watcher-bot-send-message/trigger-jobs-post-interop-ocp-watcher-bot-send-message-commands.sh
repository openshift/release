#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset postTaskStep= postTaskPars=
typeset postTaskName="${HOSTNAME#${JOB_NAME_SAFE}-}"
typeset -i dryRun=0 postTaskFlgs=0

typeset jobList=
typeset secretDir="/tmp/bot_secrets"
typeset botJobList="/tmp/job-list"
typeset -a botJobArr=()

### Legacy code start. To be replaced when all Job List are migrated to new. ###
# Get the day of the month.
typeset -i month_day=$(date +%-d)

# additional checks for self-managed fips and non-fips testing
self_managed_string='self-managed-lp-interop-jobs'
zstream_string='zstream'
fips_string='fips'

# only report self-managed fips if date <= 7 and non-fips scenarios if date > 7 .
: "Checking to see if it is a test day for ${JT__TRIG_JOB_LIST}"
if [[ $JT__TRIG_JOB_LIST == *"${self_managed_string}"* &&
        $JT__TRIG_JOB_LIST != *"$fips_string"* &&
        $JT__TRIG_JOB_LIST != *"$zstream_string"* ]]; then
  if (( $month_day > 7 )); then
    : "Reporting jobs because it's a Monday not in the first week of the month."
    : 'Continue...'
    touch "${SHARED_DIR}/trigger-jobs-post-interop-ocp-watcher-bot-send-message"
  else
    : 'We do not run self-managed scenarios on first week of the month, skip reporting'
    exit 0
  fi
fi

if [[ $JT__TRIG_JOB_LIST == *"${self_managed_string}"* &&
        $JT__TRIG_JOB_LIST == *"$fips_string"* &&
        $JT__TRIG_JOB_LIST != *"$zstream_string"* ]]; then
  if (( $month_day <= 7 )); then
    : "Reporting jobs because it's the first Monday of the month."
    : 'Continue...'
    touch "${SHARED_DIR}/trigger-jobs-post-interop-ocp-watcher-bot-send-message"
  else
    : 'We do not run self-managed fips scenarios past the first Monday of the month, skip reporting'
    exit 0
  fi
fi
################################################################################

[[ "${JOB_NAME}" == 'rehearse-'* ]] && dryRun=1

while IFS=$'\t' read -r postTaskFlgs postTaskStep postTaskPars jobList; do
    typeset execTaskFlag=
    ((postTaskFlgs && JT__POST_TASK_EXEC_FLGS)) || continue
    [ "${postTaskStep}" = "${postTaskName}" ] || continue
    IFS=$'\t' read -r execTaskFlag 0< <(
        echo "${postTaskPars}" |
        jq -cr \
            --arg defVal "${postTaskStep}" \
            '.execTaskFlag//$defVal'
    )
    [ -f "${SHARED_DIR}/${execTaskFlag}" ] || {
        : 'Skipping Job.'
        continue
    }
    ####    Main Logic                                                      ####
    botJobArr+=("$(
        echo "${jobList}" |
        jq -cr '.[] | {jobName: .jobName, active: .active}'
    )")
    ############################################################################
done 0< <(jq -cr '
    .[] as $parent |
    .postTask//[] |
    .[] |
    [.postTaskFlgs//0, .postTaskStep//"", (.postTaskPars//{} | @json), ($parent.jobList//[] | @json)] |
    @tsv
' "${CLUSTER_PROFILE_DIR}/${JT__TRIG_JOB_LIST}")

((${#botJobArr[@]})) && {
    printf '%s\n' "${botJobArr[@]}" | jq -cs '.' 1> "${botJobList}"

    echo "Executing interop-ocp-watcher-bot..."
        eval "$(cat - 0<<cmd1EOF
$(((dryRun)) && echo echo || echo eval) $(printf '%q' "$(cat - 0<<cmd2EOF
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
