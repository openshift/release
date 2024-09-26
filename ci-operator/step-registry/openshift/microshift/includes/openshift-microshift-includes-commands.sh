#!/bin/bash
set -xeuo pipefail

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
        export PULL_SECRET="${HOME}/.pull-secret.json"
        cp /tmp/pull-secret "${PULL_SECRET}"
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

    # Attempt registration with retries
    for try in $(seq 3) ; do
        echo "Trying to register the system: attempt #${try}"
        if sudo subscription-manager register \
                --org="$(cat /tmp/subscription-manager-org)" \
                --activationkey="$(cat /tmp/subscription-manager-act-key)" ; then
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
    local -r go_version=$(go version | awk '{print $3}' | tr -d '[a-z]' | cut -f2 -d.)
    if (( go_version < 22 )); then
        # Releases that use older Go, cannot compile the most recent prow code.
        # Following checks out last commit that specified 1.21 as required, but is still buildable with 1.20.
        mkdir -p /tmp/prow
        cd /tmp/prow
        git init
        git remote add origin https://github.com/kubernetes-sigs/prow.git
        git fetch origin 1a7a18f054ada0ed638678c1ee742ecfc9742958
        git reset --hard FETCH_HEAD
    else
        git clone --depth 1 https://github.com/kubernetes-sigs/prow.git /tmp/prow
        cd /tmp/prow
    fi
    go build -mod=mod -o /tmp/clonerefs ./cmd/clonerefs
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

    cat >>"${report_html}" <<EOF
<html>
<head>
  <title>${report_title}</title>
  <meta name="description" content="Links to relevant logs">
  <link rel="stylesheet" type="text/css" href="/static/style.css">
  <link rel="stylesheet" type="text/css" href="/static/extensions/style.css">
  <link href="https://fonts.googleapis.com/css?family=Roboto:400,700" rel="stylesheet">
  <link rel="stylesheet" href="https://code.getmdl.io/1.3.0/material.indigo-pink.min.css">
  <link rel="stylesheet" type="text/css" href="/static/spyglass/spyglass.css">
  <style>
    body {
      background-color: #303030;
    }
    a {
        color: #FFFFFF;
    }
    a:hover {
      text-decoration: underline;
    }
    p {
      color: #FFFFFF;
    }
  </style>
</head>
<body>
EOF

    for test in "${ARTIFACT_DIR}"/scenario-info/*; do
        testname=$(basename "${test}")
        cat >>"${report_html}" <<EOF
<p>${testname}:&nbsp;
<a target="_blank" href="${url_prefix}/${testname}">directory</a>
EOF

        for file in boot_and_run.log boot.log run.log log.html ; do
            if [ -f "${test}/${file}" ]; then
                cat >>"${report_html}" <<EOF
&nbsp;/&nbsp;<a target="_blank" href="${url_prefix}/${testname}/${file}">${file}</a>
EOF
            fi
        done

        for vm in "${test}"/vms/*; do
            if [ "${vm: -4}" == ".xml" ]; then
                continue
            fi
            vmname=$(basename "${vm}")
            cat >>"${report_html}" <<EOF
&nbsp;/&nbsp;<a target="_blank" href="${url_prefix}/${testname}/vms/${vmname}/sos">${vmname} sos reports</a>
EOF
        done

        echo '</p>' >>"${report_html}"
    done

    cat >>"${report_html}" <<EOF
</body>
</html>
EOF

    # Re-enable tracing and glob expansion
    set -x
    shopt -u nullglob
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
