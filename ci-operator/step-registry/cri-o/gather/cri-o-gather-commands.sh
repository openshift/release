#!/bin/bash
set -xeuo pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"
chmod +x ${SHARED_DIR}/login_script.sh
${SHARED_DIR}/login_script.sh

timeout --kill-after 10m 400m ssh "${SSHOPTS[@]}" ${IP} -- bash - <<EOF
    sudo chown -R ${SSH_USER} /tmp/*
    sudo chmod -R 777 /tmp/artifacts/*
EOF

function getlogs() {
	echo "### Downloading logs..."
	for i in "${!SSHOPTS[@]}"; do
		if [[ ${SSHOPTS[i]} == "-l" && ${SSHOPTS[i + 1]} == "${SSH_USER}" ]]; then
			SSHOPTS[i + 1]="100"
		fi
	done
	scp -O -r "${SSHOPTS[@]}" "${SSH_USER}@${IP}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT
