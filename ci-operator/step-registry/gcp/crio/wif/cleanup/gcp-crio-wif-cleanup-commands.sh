#!/bin/bash
set -euo pipefail
[[ -s "${SHARED_DIR}/jobs2-prefix" ]] || exit 0
prefix=$(<"${SHARED_DIR}/jobs2-prefix")
[[ "$prefix" == "${NAMESPACE}-${UNIQUE_HASH}" && "$prefix" =~ ^ci-op-[a-z0-9-]+$ ]] || { echo "Rehearsal identity or configuration check failed" >&2; exit 1; }
source "${SHARED_DIR}/jobs2-login.sh"
source "${SHARED_DIR}/jobs2-resources.sh"

failed=0
zones=$(vm_zones)
for zone in $zones; do
  gcloud compute instances delete "$prefix-buildhost" --zone="$zone" --quiet || failed=1
done
firewall=$(firewalls)
if [[ -n "$firewall" ]]; then
  gcloud compute firewall-rules delete "$prefix-buildhost-ingress-allow" --quiet || failed=1
fi
deployment=$(deployments)
if [[ -n "$deployment" ]]; then
  gcloud deployment-manager deployments delete "$prefix-vpc" --quiet || failed=1
fi

for query in vm_zones firewalls deployments networks; do
  remaining=$("$query")
  [[ -z "$remaining" ]] || { echo "Cleanup incomplete: $query for $prefix"; exit 1; }
done
(( failed == 0 ))
echo "Confirmed removal of the rehearsal VM, firewall rule, deployment and VPC."
