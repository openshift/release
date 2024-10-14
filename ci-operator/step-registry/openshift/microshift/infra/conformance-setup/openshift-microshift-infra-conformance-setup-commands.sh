#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_install_status_exit_code $EXIT_CODE_CONFORMANCE_SETUP_FAILURE

if "${SRC_FROM_GIT}"; then
  branch=$(echo ${JOB_SPEC} | jq -r '.refs.base_ref')
  # MicroShift repo is recent enough to use main instead of master.
  if [ "${branch}" == "master" ]; then
    branch="main"
  fi
  CLONEREFS_OPTIONS=$(jq -n --arg branch "${branch}" '{
    "src_root": "/go",
    "log":"/dev/null",
    "git_user_name": "ci-robot",
    "git_user_email": "ci-robot@openshift.io",
    "fail": true,
    "refs": [
      {
        "org": "openshift",
        "repo": "microshift",
        "base_ref": $branch,
        "workdir": true
      }
    ]
  }')
  export CLONEREFS_OPTIONS
fi
ci_clone_src

cp /go/src/github.com/openshift/microshift/origin/skip.txt "${SHARED_DIR}/conformance-skip.txt"
cp "${SHARED_DIR}/conformance-skip.txt" "${ARTIFACT_DIR}/conformance-skip.txt"

# Disable workload partitioning for annotated pods to avoid throttling.
ssh "${INSTANCE_PREFIX}" "sudo sed -i 's/resources/#&/g' /etc/crio/crio.conf.d/11-microshift-ovn.conf"
ssh "${INSTANCE_PREFIX}" "sudo systemctl daemon-reload"
# Just for safety, restart everything from scratch.
ssh "${INSTANCE_PREFIX}" "echo 1 | sudo microshift-cleanup-data --all --keep-images"
ssh "${INSTANCE_PREFIX}" "sudo systemctl restart crio"
# Do not enable microshift to force failures should a microshift restart happen
ssh "${INSTANCE_PREFIX}" "sudo systemctl start microshift"
