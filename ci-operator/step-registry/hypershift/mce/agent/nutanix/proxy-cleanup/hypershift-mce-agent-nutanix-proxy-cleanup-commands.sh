#!/bin/bash

set -euo pipefail

hosts_file="$SHARED_DIR/nutanix_squid_allowed_hosts"
if [[ ! -e "$hosts_file" ]]; then
  exit 0
fi

identity_file="$SHARED_DIR/nutanix_ingress_tunnel_identity.json"
if [[ ! -s "$identity_file" ]] || ! jq -e \
    --arg lease "${NUTANIX_QUOTA_SLICE:-}" --arg job "${PROW_JOB_ID:-}" \
    '.schemaVersion == 1 and .lease == $lease and .prowJobID == $job' \
    "$identity_file" >/dev/null; then
  echo "The Nutanix Squid identity does not match this run."
  exit 1
fi
run_id=$(jq -er '.gatewayName | sub("^hcp-nxwg-"; "")' "$identity_file")
if [[ ! "$run_id" =~ ^[0-9a-f]{8}-[0-9a-f]{8}$ ]]; then
  echo "The Nutanix Squid identity has an invalid run ID."
  exit 1
fi

tracing_enabled=false
if [[ $- == *x* ]]; then tracing_enabled=true; fi
# Disable tracing only while sourcing the host connection settings.
set +x
# shellcheck source=/dev/null
source "$SHARED_DIR/packet-conf.sh"
if [[ "$tracing_enabled" == true ]]; then set -x; fi

ssh "${SSHOPTS[@]}" "root@$IP" bash -s -- "$run_id" <<'EOF'
set -euo pipefail

run_id=$1
squid_config="$HOME/squid.conf"
hosts_file="/tmp/nutanix_squid_allowed_hosts_${run_id}"
if [[ ! -f "$squid_config" ]]; then
  echo "The baremetal Squid config is missing."
  exit 1
fi

work_dir=$(mktemp -d "$HOME/.squid-nutanix-cleanup.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
candidate="$work_dir/config"
if awk -v run_id="$run_id" '
  BEGIN {
    acl_begin = "# BEGIN hypershift-nutanix-squid " run_id " ACL"
    acl_end = "# END hypershift-nutanix-squid " run_id " ACL"
    access_begin = "# BEGIN hypershift-nutanix-squid " run_id " ACCESS"
    access_end = "# END hypershift-nutanix-squid " run_id " ACCESS"
  }
  $0 == acl_begin { if (section != "" || ++acl_starts != 1) invalid = 1; section = "acl"; next }
  $0 == acl_end { if (section != "acl" || ++acl_ends != 1) invalid = 1; section = ""; next }
  $0 == access_begin { if (section != "" || ++access_starts != 1) invalid = 1; section = "access"; next }
  $0 == access_end { if (section != "access" || ++access_ends != 1) invalid = 1; section = ""; next }
  /^# (BEGIN|END) hypershift-nutanix-squid / { invalid = 1; next }
  section == "" { print }
  END {
    if (invalid || section != "" || acl_starts != acl_ends ||
        access_starts != access_ends || acl_starts != access_starts) exit 2
    if (acl_starts == 0) exit 3
  }
' "$squid_config" > "$candidate"; then
  chmod --reference="$squid_config" "$candidate"
  mv "$candidate" "$squid_config"
else
  status=$?
  if [[ "$status" -ne 3 ]]; then
    echo "The Nutanix Squid ACL markers are incomplete or belong to another run."
    exit 1
  fi
fi

rm -f "$hosts_file"
if sudo podman container exists external-squid; then
  sudo podman stop -t 120 external-squid
fi
sudo podman run -d --rm \
  --net host \
  --volume "$squid_config:/etc/squid/squid.conf" \
  --name external-squid \
  --dns 127.0.0.1 \
  quay.io/openshifttest/squid-proxy:multiarch
if [[ $(sudo podman inspect --format '{{.State.Running}}' external-squid) != true ]]; then
  echo "Squid did not stay running after its Nutanix ACLs were removed."
  exit 1
fi
EOF

rm -f "$hosts_file"
printf "Removed this run's Nutanix Squid ACLs from the baremetal proxy.\n"
