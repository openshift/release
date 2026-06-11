#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

MUST_GATHER_IMAGE=${MUST_GATHER_IMAGE:-""}
MUST_GATHER_TIMEOUT=${MUST_GATHER_TIMEOUT:-"15m"}

if [ ! -f "${KUBECONFIG}" ]; then
	echo "No kubeconfig, so no point in calling must-gather."
	exit 0
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Running must-gather for hosted cluster..."
mkdir -p "${ARTIFACT_DIR}/must-gather-hostedcluster"

EXTRA_MG_ARGS="${EXTRA_MG_ARGS:-""}"
if [ -n "$MUST_GATHER_IMAGE" ]; then
	EXTRA_MG_ARGS="${EXTRA_MG_ARGS} --image=${MUST_GATHER_IMAGE}"
fi
VOLUME_PERCENTAGE_FLAG=""
if oc adm must-gather --help 2>&1 | grep -q -- '--volume-percentage'; then
	VOLUME_PERCENTAGE_FLAG="--volume-percentage=100"
fi
# shellcheck disable=SC2086
oc --insecure-skip-tls-verify adm must-gather $VOLUME_PERCENTAGE_FLAG \
	--timeout="$MUST_GATHER_TIMEOUT" \
	--dest-dir "${ARTIFACT_DIR}/must-gather-hostedcluster" \
	${EXTRA_MG_ARGS} > "${ARTIFACT_DIR}/must-gather-hostedcluster/must-gather.log"
