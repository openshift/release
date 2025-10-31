#!/bin/bash
set -xeuo pipefail

printenv

if [ -z "${SHARED_DIR-}" ] ; then
    echo "The SHARED_DIR environment variable is not defined"
    exit 1
fi

cat > "${SHARED_DIR}/ci-functions.sh" <<'EOF_SHARED_DIR'
#
# Note that CI-specific functions have 'ci_' name prefix.
# The rest should be generic functionality.
#
function ci_script_prologue() {
    IP_ADDRESS="$(cat "${SHARED_DIR}/public_address")"
    export IP_ADDRESS
    HOST_USER="$(cat "${SHARED_DIR}/ssh_user")"
    export HOST_USER
    CACHE_REGION="$(cat "${SHARED_DIR}/cache_region")"
    export CACHE_REGION
    INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"
    export INSTANCE_PREFIX

    echo "Using Host $IP_ADDRESS"

    mkdir -p "${HOME}/.ssh"
    cat >"${HOME}/.ssh/config" <<EOF
Host ${IP_ADDRESS}
User ${HOST_USER}
IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
StrictHostKeyChecking accept-new
ServerAliveInterval 30
ServerAliveCountMax 1200
EOF
    chmod 0600 "${HOME}/.ssh/config"
}

function ci_copy_secrets() {
    local -r cache_region=$1

    # Set the home directory permissions
    chmod 0755 ~

    # Set up the SSH keys at the expected location
    if [ -e /tmp/ssh-publickey ] && [ -e /tmp/ssh-privatekey ] ; then
        cp /tmp/ssh-publickey ~/.ssh/id_rsa.pub
        cp /tmp/ssh-privatekey ~/.ssh/id_rsa
        chmod 0400 ~/.ssh/id_rsa*
    fi

    # Set up the pull secret at the expected location
    if [ -e /tmp/pull-secret ] ; then
        echo "Setting up a pull secret file"
        export PULL_SECRET="${HOME}/.pull-secret.json"

        if [ -e /tmp/registry.stage.redhat.io ] ; then
            cat > /tmp/pull-secret-stage <<EOF
{
    "auths": {
        "registry.stage.redhat.io": {
            "auth": "$(cat /tmp/registry.stage.redhat.io)"
        }
    }
}
EOF
            # Merge the files and save the result at the expected location
            jq -s '.[0] * .[1]' /tmp/pull-secret /tmp/pull-secret-stage > "${PULL_SECRET}"
        else
            cp /tmp/pull-secret "${PULL_SECRET}"
        fi
    fi

    # Set up the AWS CLI keys at the expected location for accessing the cached data.
    # Also, set the environment variables for using the profile and bucket.
    if [ -e /tmp/aws_access_key_id ] && [ -e /tmp/aws_secret_access_key ] ; then
        echo "Setting up AWS CLI configuration for the 'microshift-ci' profile"
        mkdir -m 0700 "${HOME}/.aws/"

        # Profile configuration
        cat >>"${HOME}/.aws/config" <<EOF

[microshift-ci]
region = ${cache_region}
output = json
EOF

        # Profile credentials
        cat >>"${HOME}/.aws/credentials" <<EOF

[microshift-ci]
aws_access_key_id = $(cat /tmp/aws_access_key_id)
aws_secret_access_key = $(cat /tmp/aws_secret_access_key)
EOF

        # Permissions and environment settings
        chmod -R go-rwx "${HOME}/.aws/"
        export AWS_PROFILE=microshift-ci
        export AWS_BUCKET_NAME="microshift-build-cache-${cache_region}"
    fi
}

function ci_subscription_register() {
    # Check if the system is already registered
    if sudo subscription-manager status >&/dev/null; then
        return 0
    fi

    if [ ! -e /tmp/subscription-manager-org ] || [ ! -e /tmp/subscription-manager-act-key ] ; then
        echo "ERROR: The subscription files do not exist in /tmp directory"
        return 1
    fi

    # Create a subscription manager registration script which will run elevated.
    # This is a workaround to avoid sudo logging its command line containing
    # secrets in the system logs.
    local -r submgr_script="$(mktemp /tmp/submgr_script.XXXXXXXX.sh)"

    cat >"${submgr_script}" <<'EOF'
#!/bin/bash
set -euo pipefail

subscription-manager register \
    --org="$(cat /tmp/subscription-manager-org)" \
    --activationkey="$(cat /tmp/subscription-manager-act-key)"
EOF
    chmod +x "${submgr_script}"

    # Attempt registration with retries
    for try in $(seq 3) ; do
        echo "Trying to register the system: attempt #${try}"
        if sudo "${submgr_script}" ; then
            rm -f "${submgr_script}"
            return 0
        fi

        sleep 5
        sudo subscription-manager unregister || true
    done

    # Attempt displaying the error log for troubleshooting
    echo "ERROR: Failed to register the system after retries"
    sudo cat /var/log/rhsm/rhsm.log || true

    return 1
}

function trap_subprocesses_on_term() {
    # Call wait regardless of the outcome of the kill command, in case some of
    # the subprocesses are finished by the time we try to kill them.
    trap 'PIDS=$(jobs -p); if test -n "${PIDS}"; then kill ${PIDS} || true && wait; fi' TERM
}

EXIT_CODE_AWS_EC2_FAILURE=3
EXIT_CODE_AWS_EC2_LOG_FAILURE=4
EXIT_CODE_LVM_INSTALL_FAILURE=5
EXIT_CODE_RPM_INSTALL_FAILURE=6
EXIT_CODE_CONFORMANCE_SETUP_FAILURE=7
EXIT_CODE_PCP_FAILURE=8
EXIT_CODE_WAIT_CLUSTER_FAILURE=9
EXIT_CODE_REBASE_FAILURE=10

function trap_install_status_exit_code() {
    local -r code=$1
    trap '([ "$?" -ne "0" ] && echo '$code' || echo 0) >> ${SHARED_DIR}/install-status.txt' EXIT
}

function download_microshift_scripts() {
    DNF_RETRY=$(mktemp /tmp/dnf_retry.XXXXXXXX.sh)
    export DNF_RETRY

    curl -s https://raw.githubusercontent.com/openshift/microshift/main/scripts/dnf_retry.sh -o "${DNF_RETRY}"
    chmod 755 "${DNF_RETRY}"
}

function ci_get_clonerefs() {
    curl -L \
        "https://github.com/microshift-io/prow/releases/download/nightly/clonerefs-linux-$(go env GOARCH)" \
        -o /tmp/clonerefs
    chmod +x /tmp/clonerefs
}

function ci_clone_src() {
    fails=0
    for _ in $(seq 3) ; do
        if ci_get_clonerefs; then
            break
        else
            fails=$((fails + 1))
            if [[ "${fails}" -ge 3 ]]; then
                echo "Failed to download and compile clonerefs"
                exit 1
            fi
            sleep 10
        fi
    done

    if [ -z ${CLONEREFS_OPTIONS+x} ]; then
        # Without `src` build, there's no CLONEREFS_OPTIONS, but it can be assembled from $JOB_SPEC
        CLONEREFS_OPTIONS=$(echo "${JOB_SPEC}" | jq '{"src_root": "/go", "log":"/dev/null", "git_user_name": "ci-robot", "git_user_email": "ci-robot@openshift.io", "fail": true, "refs": [(select(.refs) | .refs), try(.extra_refs[])]}')
        export CLONEREFS_OPTIONS
    fi

    # Following procedure is taken from original clonerefs image used to construct `src` image.
    umask 0002
    /tmp/clonerefs
    find /go/src -type d -not -perm -0775 | xargs --max-procs 10 --max-args 100 --no-run-if-empty chmod g+xw
}

function ci_custom_link_report() {
    local -r report_title="$1"
    local -r step_name="$2"
    local -r report_html="${ARTIFACT_DIR}/custom-link-tools.html"

    # Build the URL prefix
    local job_url_path
    job_url_path="logs"
    if [ "${JOB_TYPE}" == "presubmit" ]; then
        job_url_path="pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}"
    fi
    local -r url_prefix="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/${job_url_path}/${JOB_NAME}/${BUILD_ID}/artifacts/${JOB_NAME_SAFE}/${step_name}/${ARTIFACT_DIR#/logs/}/scenario-info"

    # Disable tracing and glob expansion
    set +x
    shopt -s nullglob

    # Calculate totals first
    local total_scenarios=0
    local scenarios_passed=0
    local scenarios_failed=0
    local scenarios_skipped=0
    
    for test in "${ARTIFACT_DIR}"/scenario-info/*; do
        # Skip if glob didn't match anything
        [ -d "${test}" ] || continue
        
        total_scenarios=$((total_scenarios + 1))
        
        # Find junit file
        local junit_file=""
        if [ -f "${test}/log.html" ]; then
            junit_file="${test}/junit.xml"
        elif [ -f "${test}/gingko-results/test-output.log" ]; then
            junit_file="$( find "${test}/gingko-results" -name "junit_e2e_*.xml" -type f | head -1 )"
        fi
        
        # Determine scenario status
        local scenario_status="skip"
        if [ -f "${junit_file}" ] && grep -q -E 'failures="[1-9][0-9]?"' "${junit_file}"; then
            scenario_status="fail"
        elif [ -d "${test}/vms/" ]; then
            scenario_status="pass"
        fi
        
        # Count by status
        case "${scenario_status}" in
            pass) scenarios_passed=$((scenarios_passed + 1)) ;;
            fail) scenarios_failed=$((scenarios_failed + 1)) ;;
            skip) scenarios_skipped=$((scenarios_skipped + 1)) ;;
        esac
    done

    cat >"${report_html}" <<EOF
<html>
<head>
  <title>${report_title}</title>
  <meta name="description" content="Links to relevant logs">
  <meta charset="utf-8">
  <link rel="stylesheet" type="text/css" href="/static/style.css">
  <link rel="stylesheet" type="text/css" href="/static/extensions/style.css">
  <link href="https://fonts.googleapis.com/css?family=Roboto:400,700" rel="stylesheet">
  <link rel="stylesheet" href="https://code.getmdl.io/1.3.0/material.indigo-pink.min.css">
  <link rel="stylesheet" type="text/css" href="/static/spyglass/spyglass.css">
  <style>
    body {
      background-color: #303030;
      color: #FFFFFF;
      font-family: "Roboto", "Helvetica", "Arial", sans-serif;
      padding: 32px;
    }
    h1 {
      font-size: 1.8rem;
      margin-bottom: 24px;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      background-color: #1e1e1e;
      border-radius: 8px;
      overflow: hidden;
      box-shadow: 0 10px 30px rgba(0, 0, 0, 0.4);
    }
    thead {
      background-color: #424242;
    }
    th {
      text-align: left;
      padding: 12px 16px;
      font-weight: 700;
      letter-spacing: 0.02em;
      text-transform: uppercase;
      font-size: 0.75rem;
    }
    td {
      padding: 8px 8px 8px 8px;
      border-top: 1px solid rgba(255, 255, 255, 0.1);
    }
    tr:nth-child(even) {
      background-color: rgba(255, 255, 255, 0.04);
    }
    a {
      color: #ffffff;
      text-decoration: unset;
    }
    a:hover {
      color: #558af4;
    }
    .status-emoji {
      font-size: 1.5rem;
      text-align: center;
      width: 3.5rem;
    }
    .status-pass {
      color: #9ccc65;
    }
    .status-fail {
      color: #ff0000;
    }
    .status-skip {
      color: #ffd54f;
    }
    .cell-links a {
      display: inline-flex;
      align-items: center;
      gap: 6px;
    }
    .scenario-link {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      color: #FFFFFF;
    }
    .scenario-link:hover {
      color: #82b1ff;
      text-decoration: none;
    }
    .tag {
      display: inline-block;
      padding: 4px 8px;
      border-radius: 999px;
      background-color: rgba(130, 177, 255, 0.16);
      border: 1px solid rgba(130, 177, 255, 0.28);
      font-size: 0.8rem;
      margin-right: 6px;
    }
    .empty-state {
      color: #ffd54f;
    }
    .none-state {
      color: #ffffff;
    }
    .none-state:hover {
      color: #ffffff;
    }
    .version-badge {
      display: inline-block;
      padding: 4px 10px;
      background-color: rgba(130, 177, 255, 0.16);
      border: 1px solid rgba(130, 177, 255, 0.28);
      border-radius: 4px;
      font-size: 0.85rem;
      color: #82b1ff;
      font-family: monospace;
      word-break: break-all;
    }
    .summary-container {
      margin-bottom: 32px;
      background-color: #1e1e1e;
      padding: 24px 32px;
      border-radius: 8px;
      box-shadow: 0 10px 30px rgba(0, 0, 0, 0.4);
    }
    .summary-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 20px;
      gap: 16px;
      flex-wrap: wrap;
    }
    .summary-title-section {
      display: flex;
      align-items: center;
      gap: 12px;
      flex-wrap: wrap;
    }
    .summary-title {
      font-size: 1.5rem;
      font-weight: 700;
      color: #ffffff;
    }
    .summary-version {
      display: inline-flex;
      align-items: center;
      padding: 6px 12px;
      background-color: rgba(130, 177, 255, 0.16);
      border: 1px solid rgba(130, 177, 255, 0.28);
      border-radius: 6px;
      font-size: 0.85rem;
      color: #82b1ff;
      font-weight: 500;
    }
    .summary-stats {
      display: flex;
      gap: 16px;
    }
    .stat-card {
      background-color: rgba(255, 255, 255, 0.04);
      padding: 16px;
      border-radius: 8px;
      text-align: center;
      border: 1px solid rgba(255, 255, 255, 0.1);
      flex: 1;
      min-width: 140px;
    }
    .stat-value {
      font-size: 2rem;
      font-weight: 700;
      margin-bottom: 4px;
    }
    .stat-label {
      font-size: 0.8rem;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      opacity: 0.9;
    }
    .stat-pass {
      color: #9ccc65;
    }
    .stat-fail {
      color: #ff5252;
    }
    .stat-total {
      color: #82b1ff;
    }
    .stat-skip {
      color: #ffd54f;
    }
    .summary-links {
      display: flex;
      gap: 12px;
      align-items: center;
    }
    .summary-link {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 10px 20px;
      background-color: rgba(255, 255, 255, 0.04);
      border-radius: 6px;
      border: 1px solid rgba(255, 255, 255, 0.1);
      color: #ffffff;
      text-decoration: none;
      font-weight: 500;
      transition: all 0.2s ease;
      white-space: nowrap;
    }
    .summary-link:hover {
      background-color: rgba(255, 255, 255, 0.08);
      border-color: rgba(255, 255, 255, 0.2);
      color: #558af4;
    }
  </style>
</head>
<body>
  <div class="summary-container">
    <div class="summary-header">
      <div class="summary-title-section">
        <div class="summary-title">📊 Test Run Summary</div>
      </div>
      <div class="summary-links">
        <a class="summary-link" target="_blank" href="${url_prefix}/">
          📁 Scenarios Directory
        </a>
        <a class="summary-link" target="_blank" href="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/${job_url_path}/${JOB_NAME}/${BUILD_ID}/artifacts/${JOB_NAME_SAFE}/${step_name}/build-log.txt">
          📃 Build Log
        </a>
      </div>
    </div>
    <div class="summary-stats">
      <div class="stat-card">
        <div class="stat-value stat-total">${total_scenarios}</div>
        <div class="stat-label">Scenarios Executed</div>
      </div>
      <div class="stat-card">
        <div class="stat-value stat-pass">${scenarios_passed}</div>
        <div class="stat-label">Scenarios Passed</div>
      </div>
      <div class="stat-card">
        <div class="stat-value stat-fail">${scenarios_failed}</div>
        <div class="stat-label">Scenarios Failed</div>
      </div>
      <div class="stat-card">
        <div class="stat-value stat-skip">${scenarios_skipped}</div>
        <div class="stat-label">Scenarios Skipped</div>
      </div>
    </div>
  </div>
  <table>
    <thead>
      <tr>
        <th>Status</th>
        <th>Scenario</th>
        <th>MicroShift Version</th>
        <th>Test Results</th>
        <th>Boot &amp; Run</th>
        <th>Test Report</th>
        <th>VM SOS Reports</th>
      </tr>
    </thead>
    <tbody>
EOF
    
    for test in "${ARTIFACT_DIR}"/scenario-info/*; do
        junit_file=""
        # RF or gingko
        if [ -f "${test}/log.html" ]; then
            junit_file="${test}/junit.xml"
        elif [ -f "${test}/gingko-results/test-output.log" ]; then
            junit_file="$( find "${test}/gingko-results" -name "junit_e2e_*.xml" -type f | head -1 )"
        fi

        # set scenario status
        testname=$(basename "${test}")
        status_class="status-pass"
        status_emoji="✅"
        if [ ! -d "${test}/vms/" ]; then
            status_class="status-skip"
            status_emoji="⚠️"
        elif [ -f "${junit_file}" ] && grep -q -E 'failures="[1-9][0-9]?"' "${junit_file}"; then
            status_class="status-fail"
            status_emoji="❌"
        fi

        # set scenario name
        scenario_cell="<a class=\"scenario-link\" target=\"_blank\" href=\"${url_prefix}/${testname}\">${testname}</a>"

        # get microshift version from journal log
        version_cell="<span class=\"version-badge\">-</span>"
        local journal_file="$(ls ${test}/vms/*/sos/journal_*.log 2>/dev/null | head -1)"
        if [ -f "${journal_file}" ]; then
            local ms_version=$(grep -oP '"Version" microshift="\K[^"]+' "${journal_file}" 2>/dev/null | tail -1)
            if [ -n "${ms_version}" ]; then
                version_cell="<span class=\"version-badge\"><code>${ms_version}</code></span>"
            fi
        fi

        # set test results
        test_results_cell="<span class=\"none-state\">0</span>"
        if [ -f "${junit_file}" ]; then
          total_tests=$(grep -oP 'tests="\K[0-9]+' "${junit_file}" | head -1)
          failures=$(grep -oP 'failures="\K[0-9]+' "${junit_file}" | head -1)
          errors=$(grep -oP 'errors="\K[0-9]+' "${junit_file}" | head -1)
          passed=$((${total_tests:-0} - ${failures:-0} - ${errors:-0}))
          failed=$((${failures:-0} + ${errors:-0}))
          total_tests=${total_tests:-0}
          if [ "${total_tests}" -gt 0 ]; then
              if [ "${passed}" -gt 0 ]; then
                  passed_span="<span class=\"status-pass\">${passed}</span>"
              else
                  passed_span="<span class=\"none-state\">0</span>"
              fi
              if [ "${failed}" -gt 0 ]; then
                  failed_span="<span class=\"status-fail\">${failed}</span>"
              else
                  failed_span="<span class=\"none-state\">0</span>"
              fi
              test_results_cell="${passed_span}<span class=\"none-state\">+</span>${failed_span}<span class=\"none-state\">=${total_tests}</span>"
          fi
        fi

        # set boot and run logs
        boot_run_cell="<span class=\"empty-state\">No run logs</span>"
        if [ -f "${test}/boot_and_run.log" ]; then
            boot_run_cell="<div class=\"cell-links\"><a target=\"_blank\" href=\"${url_prefix}/${testname}/boot_and_run.log\">📃 boot_and_run.log</a></div>"
        fi

        # set test report
        html_report_cell="<span class=\"empty-state\">No test logs</span>"
        if [ -f "${test}/log.html" ]; then
            html_report_cell="<div class=\"cell-links\"><a target=\"_blank\" href=\"${url_prefix}/${testname}/log.html\">🤖 log.html</a></div>"
        elif [ -f "${test}/gingko-results/test-output.log" ]; then
            html_report_cell="<div class=\"cell-links\"><a target=\"_blank\" href=\"${url_prefix}/${testname}/ginkgo-results/test-output.log\">☘️ test-output.log</a></div>"
        fi

        # set SOS reports
        vm_links=""
        for vm in "${test}"/vms/*; do
            if [[ "${vm}" == *.xml ]]; then
                continue
            fi
            if [ ! -d "${vm}" ]; then
                continue
            fi
            vmname=$(basename "${vm}")
            if [ -n "${vm_links}" ]; then
                vm_links="${vm_links}<br>"
            fi
            vm_links="${vm_links}<div class=\"cell-links\"><a target=\"_blank\" href=\"${url_prefix}/${testname}/vms/${vmname}/sos\">🔎 SOS Reports</a></div>"
        done
        if [ -z "${vm_links}" ]; then
            vm_links="<span class=\"empty-state\">No SOS report</span>"
        fi

        cat >>"${report_html}" <<EOF
      <tr class="${status_class}">
        <td class="status-emoji">${status_emoji}</td>
        <td class>${scenario_cell}</td>
        <td class="cell-links">${version_cell}</td>
        <td class="cell-links">${test_results_cell}</td>
        <td class="cell-links">${boot_run_cell}</td>
        <td class="cell-links">${html_report_cell}</td>
        <td class="cell-links">${vm_links}</td>
      </tr>
EOF
    done

    cat >>"${report_html}" <<EOF
    </tbody>
  </table>
</body>
</html>
EOF

    # Re-enable tracing and glob expansion
    set -x
    shopt -u nullglob
}

# Implement scenario directory check with fallbacks. Simplify or remove the
# function when the structure is homogenised in all the active releases.
function get_source_dir() {
  declare -A SCENARIO_DIRS=(
    [bootc-upstream]="scenarios-bootc/upstream:scenarios-bootc"
    [bootc-releases]="scenarios-bootc/releases:scenarios-bootc"
    [bootc-presubmits]="scenarios-bootc/presubmits:scenarios-bootc"
    [bootc-periodics]="scenarios-bootc/periodics:scenarios-bootc"
    [releases]="scenarios/releases:scenarios"
    [presubmits]="scenarios/presubmits:scenarios"
    [periodics]="scenarios/periodics:scenarios-periodics"
  )
  local -r scenario_type=$1
  local -r base="/home/${HOST_USER}/microshift/test"
  local -r dirs="${SCENARIO_DIRS[$scenario_type]}"
  local -r ndir="${base}/$(echo "$dirs" | cut -d: -f1)"
  local -r fdir="${base}/$(echo "$dirs" | cut -d: -f2)"

  # We need the variable to expand on the client side
  # shellcheck disable=SC2029
  if ssh "${INSTANCE_PREFIX}" "[ -d \"${ndir}\" ]" ; then
    echo "${ndir}"
  else
    echo "${fdir}"
  fi
}

#
# Enable tracing with the following format after loading the functions:
# - Time in hh:mm:ss.ns
# - Script file name with $HOME prefix stripped ($0 is used if BASH_SOURCE is undefined)
# - Script line number
#
function format_ps4() {
    local -r date=$(date "+%T.%N")
    local -r file=$1
    local -r line=$2
    echo -en "+ ${date} ${file#"${HOME}/"}:${line} \011"
}
export -f format_ps4
export PS4='$(format_ps4 "${BASH_SOURCE:-$0}" "${LINENO}")'
EOF_SHARED_DIR
