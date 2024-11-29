#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Fix container user ************"
# Fix user IDs in a container
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function set_expiration_time {

  echo "************ Set OCP cluster expiration time ************"

  SSHOPTS=(
    -o 'ConnectTimeout=5'
    -o 'StrictHostKeyChecking=no'
    -o 'UserKnownHostsFile=/dev/null'
    -o 'ServerAliveInterval=90'
    -o LogLevel=ERROR
    -i "${CLUSTER_PROFILE_DIR}/ssh-key"
  )

  local_exp_time_file=$(mktemp --dry-run --suffix=.iso-8601.time)
  remote_exp_time=/var/builds/${NAMESPACE}/preserve

  TZ=UTC date --iso-8601=seconds -d "${EXPIRATION_TIME}" > ${local_exp_time_file}

  rsync -avP \
    -e "ssh $(echo "${SSHOPTS[@]}")" \
    "${local_exp_time_file}" \
    "root@${AUX_HOST}":${remote_exp_time}
}

if [ -n "${PULL_NUMBER:-}" ]; then
  echo "Running from pull request ${PULL_NUMBER}. Skipping cluster preservation..."
else
  set_expiration_time
fi
