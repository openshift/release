#!/bin/bash
dest_dir=$(mktemp --dir --tmpdir="$ARTIFACT_DIR")
oc adm must-gather --dest-dir="$dest_dir" --image=quay.io/openshift/origin-must-gather -- /usr/bin/gather_audit_logs
mv "$dest_dir"/*/audit_logs "$ARTIFACT_DIR/audit-logs"
rm -Rf "$dest_dir"