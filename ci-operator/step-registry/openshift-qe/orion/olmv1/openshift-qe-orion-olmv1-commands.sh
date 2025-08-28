#!/bin/bash

echo "Current dir: $(pwd)"
ls -al ../

REPO_ROOT="/go/src/github.com/openshift/release"
ls -l $REPO_ROOT
"$REPO_ROOT/ci-operator/step-registry/openshift-qe/orion/openshift-qe-orion-commands.sh"

if [[ "$OUTPUT_FORMAT" == "JUNIT" ]]; then
  # Remove timestamps field since RP doesn't support it, 
  # details: https://redhat-internal.slack.com/archives/CH76YSYSC/p1754418769901119?thread_ts=1754385612.115479&cid=CH76YSYSC
  python3 <<'EOF'
import xml.etree.ElementTree as ET

artifact_dir = os.environ.get("ARTIFACT_DIR", ".")
file_path = f"{artifact_dir}/junit_olmv1-GCP.xml"
print(file_path)
try:
    tree = ET.parse(file_path)
    root = tree.getroot()

    for testcase in root.findall('.//testcase'):
        testcase.attrib.pop("timestamp", None)

    tree.write(file_path, encoding='utf-8', xml_declaration=True)
    print(f"Successfully removed timestamps and saved to {file_path}")

except ET.ParseError as e:
    print(f"Error parsing XML file: {e}")
except IOError as e:
    print(f"Error reading or writing file: {e}")
EOF
fi

send_slack_notification() {
  local jobID="$1"

  SLACK_WEBHOOK_URL=$(cat /var/run/vault/mirror-registry/olm_slack_channel 2>/dev/null)
  export SLACK_WEBHOOK_URL

  if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    echo "Error: SLACK_WEBHOOK_URL environment variable is required."
    return 1
  fi

  export PYTHONPATH="/go/src/github.com/openshift/openshift-tests-private/hack/:${PYTHONPATH:-}"

  python3 - <<EOF
from slack_notify import SlackClient
import os

webhook_url = os.getenv("SLACK_WEBHOOK_URL")
notificationList = [
    "*OLMv1 Performance Abnormal Notification* :zap:",
    "Prow Job: ${jobID}"
]

try:
    client = SlackClient()
    client.notify_to_slack(webhook_url, notificationList)
except Exception as e:
    print(f"Failed to send Slack notification: {e}")
    sys.exit(1)
EOF
}

notify_slack_if_failure() {
  local xml_file="$1"

  if [[ ! -f "$xml_file" ]]; then
    echo "Error: File $xml_file not found" >&2
    return 1
  fi

  local failures
  failures=$(sed -n 's/.*failures="\([0-9]*\)".*/\1/p' "$xml_file" | head -n1)

  echo "[DEBUG] Detected failures = '$failures'"

  if [[ -z "$failures" || ! "$failures" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Unable to parse failure count from XML." >&2
    return 1
  fi

  if [[ "$failures" != "0" ]]; then
    echo "Test failure detected, sending Slack notification..."

    local prow_base_url="https://qe-private-deck-ci.apps.ci.l2s4.p1.openshiftapps.com/view/gs/qe-private-deck/logs"
    local prow_link="N/A"
    if [[ -n "${JOB_NAME:-}" && -n "${BUILD_ID:-}" ]]; then
      prow_link="${prow_base_url}/${JOB_NAME}/${BUILD_ID}"
    fi
    send_slack_notification "$prow_link"
    
  else
    echo "All tests passed. No Slack notification sent."
  fi
}

notify_slack_if_failure "junit_olmv1-GCP.xml"
