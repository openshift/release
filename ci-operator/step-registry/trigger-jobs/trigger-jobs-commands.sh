#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset jobDescFile="${CLUSTER_PROFILE_DIR}/${JT__TRIG_JOB_LIST}"
typeset trigCond= trigCondStep= trigCondPars=
typeset jobList= jobType= jobName= stepName=
typeset postTask= postTaskStep= postTaskPars=
typeset -i dryRun=0 trigCondFlgs=0 postTaskFlgs=0 jobExecType=0 tryLeft=0 retryWait=60
typeset -a failedJobs=()
#   https://github.com/kubernetes-sigs/prow/blob/95b2a34128de51a4f618c8d6bb9d0c6b587fd29c/pkg/gangway/gangway.proto#L108
typeset -Ai jobExecTypeMaps=(
    [periodic]=1
#   [postsubmit]=2  # Not currently supported, because it requires extra `git`
#   [presubmit]=3   #   ref. parameters, which are not easy to get. Potential
#   [batch]=4       #   for future enhancement.
)

typeset gangwayAPIurlPfx='https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions'
typeset gangwayAPItoken="$(cat "${CLUSTER_PROFILE_DIR}/${JT__GW__API_TOKEN}")"

### Legacy code start. To be replaced with custom trigger condition Step.    ###
# Get the day of the month.
typeset -i month_day=$(date +%-d)

# additional checks for self-managed fips and non-fips testing
self_managed_string='self-managed-lp-interop-jobs'
zstream_string='zstream'
fips_string='fips'

# only run self-managed fips if date <= 7 and non-fips scenarios if date > 7 .
: "Checking to see if it is a test day for ${JT__TRIG_JOB_LIST}"
if [[ $JT__TRIG_JOB_LIST == *"${self_managed_string}"* &&
        $JT__TRIG_JOB_LIST != *"$fips_string"* &&
        $JT__TRIG_JOB_LIST != *"$zstream_string"* ]]; then
        if (( $month_day > 7 )); then
    : "Triggering jobs because it's a Monday not in the first week of the month."
    : 'Continue...'
    touch "${SHARED_DIR}/trigger-jobs-post-interop-ocp-watcher-bot-send-message"
  else
    : 'We do not run self-managed scenarios on first week of the month.'
    exit 0
  fi
fi

if [[ $JT__TRIG_JOB_LIST == *"${self_managed_string}"* &&
        $JT__TRIG_JOB_LIST == *"$fips_string"* &&
        $JT__TRIG_JOB_LIST != *"$zstream_string"* ]]; then
  if (( $month_day <= 7 )); then
    : "Triggering jobs because it's the first Monday of the month."
    : 'Continue...'
    touch "${SHARED_DIR}/trigger-jobs-post-interop-ocp-watcher-bot-send-message"
  else
    : 'We do not run self-managed fips scenarios past the first Monday of the month.'
    exit 0
  fi
fi
################################################################################

: "Printing the jobs-to-trigger JSON:"
jq -c '.[]' "${jobDescFile}"

[[ "${JOB_NAME}" == 'rehearse-'* ]] && dryRun=1

if [ "${JT__SKIP_HC}" = "false" ]; then
  : 'Test to make sure Gangway API is up and running.'
  for ((tryLeft=60; tryLeft; tryLeft--)); do
    rsp="$(eval "$(cat - 0<<cmd1EOF
$(((dryRun)) && echo echo || echo eval) $(printf '%q' "$(cat - 0<<cmd2EOF
    curl -sSL -X GET -w '%{http_code}' -o /dev/null \
        -d $(printf '%q' "$(
            jq -cnr \
                --arg jeType 1 \
                '.job_execution_type=$jeType'
        )") \
        -H 'Authorization: Bearer '${gangwayAPItoken@Q} \
        ${gangwayAPIurlPfx@Q}/${PROW_JOB_ID@Q}
cmd2EOF
)") $(((dryRun)) && echo '1>&2; echo 200')
cmd1EOF
    )")"
    ((rsp == 200)) && break || {
        ((tryLeft - 1)) && : "Retrying $((tryLeft - 1))..."
    }
    sleep ${retryWait}
  done
  ((rsp == 200)) || { echo "Endpoint is still not available after 60 retries. Aborting." 1>&2; exit 1; }
fi

while IFS=$'\t' read -r trigCond jobList postTask; do
    # Trigger Conditions Check.
    while IFS=$'\t' read -r trigCondFlgs trigCondStep trigCondPars; do
        ((trigCondFlgs && JT__TRIG_COND_EXEC_FLGS)) || continue
        stepName="${trigCondStep}"
        while true; do
            case ${stepName} in
            # (trigger-jobs-trig-future-special-handling-no-common)     break;;
            # (trigger-jobs-trig-future-special-handling-with-common)   stepName=-common-;;
              (trigger-jobs-trig-check-resource-owner)
                typeset trigCondFlag= expOwnerName=
                IFS=$'\t' read -r trigCondFlag expOwnerName 0< <(
                    echo "${trigCondPars}" |
                    jq -cr \
                        --arg defVal "${trigCondStep}" \
                        '[.trigCondFlag//$defVal, .expOwnerName//""] | @tsv'
                )
                stepName=-common-
                ;;
            # (
            #     trigger-jobs-trig-future-standard-handling
            # ) ;&
              (trigger-jobs-trig-*)
                # Standard handling code.
                typeset trigCondFlag=
                IFS=$'\t' read -r trigCondFlag 0< <(
                    echo "${trigCondPars}" |
                    jq -cr \
                        --arg defVal "${trigCondStep}" \
                        '.trigCondFlag//$defVal'
                )
                ;&
              (-common-)
                # Common handling code.
                [ -f "${SHARED_DIR}/${trigCondFlag}" ] || {
                    : 'The trigger condition is not met. Skipping Job.'
                    continue 3
                }
                break
                ;;
              (*)   : "Unsupported Trigger Condition Step: ${trigCondStep}"; continue 3;;
            esac
        done
    done 0< <(
        echo "${trigCond}" |
        jq -cr '.[] | [.trigCondFlgs//0, .trigCondStep//"", (.trigCondPars//{} | @json)] | @tsv'
    )

    # Triggering Jobs.
    while IFS=$'\t' read -r jobType jobName; do
        : "Issuing trigger for active job: ${jobName}"
        jobExecType="${jobExecTypeMaps[${jobType}]:-}"
        ((jobExecType)) || {
            : "Invalid \`.jobType\` value: ${jobType}"
            exit 1
        }
        for ((tryLeft=3; tryLeft; tryLeft--)); do
            rsp="$(eval "$(cat - 0<<cmd1EOF
$(((dryRun)) && echo echo || echo eval) $(printf '%q' "$(cat - 0<<cmd2EOF
    curl -sSL -X GET -w '%{http_code}' -o /dev/null \
        -d $(printf '%q' "$(
            jq -cnr \
                --arg jeType "${jobExecType}" \
                '.job_execution_type=$jeType'
        )") \
        -H 'Authorization: Bearer '${gangwayAPItoken@Q} \
        ${gangwayAPIurlPfx@Q}/${PROW_JOB_ID@Q}
cmd2EOF
)") $(((dryRun)) && echo '1>&2; echo 200')
cmd1EOF
            )")"
            ((rsp == 200)) && break || {
                ((tryLeft - 1)) && : "Retrying $((tryLeft - 1))..."
            }
            sleep ${retryWait}
        done
        ((rsp == 200)) || failedJobs+=("${jobName}")
    done 0< <(
        ((JT__SKIP_TRIG_MAIN_JOBS)) && exit
        echo "${jobList}" |
        jq -cr '.[] | select(.active == true) | [.jobType//"periodic", .jobName//""] | @tsv'
    )

    # Post Tasks Execution.
    while IFS=$'\t' read -r postTaskFlgs postTaskStep postTaskPars; do
        ((postTaskFlgs && JT__POST_TASK_EXEC_FLGS)) || continue
        stepName="${postTaskStep}"
        while true; do
            case ${stepName} in
            # (trigger-jobs-post-future-special-handling-no-common)     break;;
            # (trigger-jobs-post-future-special-handling-with-common)   stepName=-common-;;
            # (
            #     trigger-jobs-post-interop-ocp-watcher-bot-send-message |
            #     trigger-jobs-post-future-standard-handling
            # ) ;&
              (trigger-jobs-post-*)
                # Standard handling code.
                typeset execTaskFlag=
                IFS=$'\t' read -r execTaskFlag 0< <(
                    echo "${postTaskPars}" |
                    jq -cr \
                        --arg defVal "${postTaskStep}" \
                        '.execTaskFlag//$defVal'
                )
                ;&
              (-common-)
                # Common handling code.
                touch "${SHARED_DIR}/${execTaskFlag}"
                break
                ;;
              (*)   : "Unsupported Post Task Step: ${postTaskStep}"; continue 3;;
            esac
        done
    done 0< <(
        echo "${postTask}" |
        jq -cr '.[] | [.postTaskFlgs//0, .postTaskStep//"", (.postTaskPars//{} | @json)] | @tsv'
    )
done 0< <(jq -cr '
    .[] | (
        if has("job_name") then
            {jobList: [{jobName: .job_name, active: .active}]}
        else
            .
        end
    ) | [(.trigCond//[] | @json), (.jobList//[] | @json), (.postTask//[] | @json)] | @tsv
' "${jobDescFile}")

# Print the list of failed jobs after the loop completes.
((${#failedJobs[@]})) && (
    set +x
    echo 'The following jobs failed to trigger and need manual re-run:'
    printf '  - %s\n' "${failedJobs[@]}"
)

true
