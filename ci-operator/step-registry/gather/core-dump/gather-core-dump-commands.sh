#!/bin/bash
#set -x

# Check if proxy is set
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  echo "Private cluster setting proxy"
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering extra artifacts."
	exit 0
fi

echo "Gathering node core dumps ..."

mkdir -p ${ARTIFACT_DIR}/core-dumps

oc adm must-gather --dest-dir="${ARTIFACT_DIR}/core-dumps" -- sh -c "/usr/bin/gather_core_dumps || true"
tar -czC "${ARTIFACT_DIR}/core-dumps" -f "${ARTIFACT_DIR}/core.dumps.tar.gz" .
rm -rf "${ARTIFACT_DIR}/core-dumps"
