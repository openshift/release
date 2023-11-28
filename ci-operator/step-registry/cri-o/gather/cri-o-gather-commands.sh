#!/bin/bash
set -xeuo pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"
chmod +x ${SHARED_DIR}/login_script.sh
${SHARED_DIR}/login_script.sh

timeout --kill-after 10m 400m ssh "${SSHOPTS[@]}" ${IP} -- bash - <<EOF
    sudo chown -R ${USER} /tmp/*
    sudo chmod -R 777 /tmp/artifacts/*
EOF


function getlogs() {
    echo "### Downloading logs..."
    for ((i = 0; i < ${#SSHOPTS[@]}; i++)); do
      if [[ ${SSHOPTS[i]} == "-l" && ${SSHOPTS[i + 1]} == "${USER}" ]]; then
        # Remove the "-l" and "deadbeef" options from the SSHOPTS array
        SSHOPTS=("${SSHOPTS[@]:0:i}" "${SSHOPTS[@]:i + 2}")
      fi
    done
    scp -rv "${SSHOPTS[@]}" "${USER}@${IP}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT
