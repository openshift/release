#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

PULL_EVENTS_ART="${ARTIFACT_DIR}/image_pull_events.txt"
WARNING_EVENTS_ART="${ARTIFACT_DIR}/warning_events.txt"

# Collect all image pull events from the testing cluster
# The output will contain the timestamp and the event message
# in a comma-separated value format
echo "[$(date --utc +%FT%T.%3NZ)] Collecting all image pull events from the testing cluster in ${PULL_EVENTS_ART}"
oc get events --all-namespaces --field-selector reason==Pulling -o go-template='{{range .items}}{{.lastTimestamp}},{{.message}}{{"\n"}}{{end}}' > "${PULL_EVENTS_ART}"

# Collect all AppliedWithWarnings events from the testing cluster
echo "[$(date --utc +%FT%T.%3NZ)] Collecting all AppliedWithWarnings events from the testing cluster in ${WARNING_EVENTS_ART}"
oc get events --all-namespaces --field-selector reason=AppliedWithWarnings > "${WARNING_EVENTS_ART}"

 echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution Successfully !"
    