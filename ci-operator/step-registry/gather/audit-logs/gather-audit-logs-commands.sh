#!/bin/bash

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering audit logs."
	exit 0
fi

mkdir -p "${ARTIFACT_DIR}/audit-logs"
oc adm must-gather --dest-dir="${ARTIFACT_DIR}/audit-logs" -- /usr/bin/gather_audit_logs
tar -czC "${ARTIFACT_DIR}/audit-logs" -f "${ARTIFACT_DIR}/audit-logs.tar.gz" .
rm -rf "${ARTIFACT_DIR}/audit-logs"
