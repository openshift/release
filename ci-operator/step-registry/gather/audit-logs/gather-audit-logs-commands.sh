#!/bin/bash

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering audit logs."
	exit 0
fi

oc adm must-gather --dest-dir="$ARTIFACT_DIR" -- /usr/bin/gather_audit_logs
