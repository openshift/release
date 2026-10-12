#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
source "${SHARED_DIR}/packet-conf.sh"

routes_json=$(oc get routes -A -o json)
hosts=$(jq -r '.items[] | select(.metadata.namespace == "multicluster-engine" or .metadata.namespace == "openshift-multicluster-engine") | select((((.metadata.name // "") + " " + (.spec.to.name // "")) | test("assisted.*(service|image)|service.*assisted"; "i"))) | .spec.host // empty' <<<"${routes_json}" | sort -u)
if [[ -z "${hosts}" ]]; then
  echo "No Assisted Service route was discovered; refusing to broaden the Squid ACL."
  exit 1
fi

printf '%s\n' "${hosts}" > "${SHARED_DIR}/nutanix_squid_allowed_hosts"
scp "${SSHOPTS[@]}" "${SHARED_DIR}/nutanix_squid_allowed_hosts" "root@${IP}:/tmp/nutanix_squid_allowed_hosts"
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s <<'EOF'
set -euo pipefail
while IFS= read -r host; do
  [[ -n "${host}" ]] || continue
  if [[ ! "${host}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "Refusing invalid Squid destination ${host}"
    exit 1
  fi
  if ! grep -Fq " ${host}" /root/squid.conf; then
    sed -i "1 s|$| ${host}|" /root/squid.conf
  fi
done < /tmp/nutanix_squid_allowed_hosts
rm -f /tmp/nutanix_squid_allowed_hosts
sudo podman stop -t 120 external-squid
sudo podman run -d --rm --net host \
  --volume /root/squid.conf:/etc/squid/squid.conf \
  --name external-squid --dns 127.0.0.1 quay.io/openshifttest/squid-proxy:multiarch
for attempt in $(seq 1 10); do
  if sudo podman inspect --format '{{.State.Running}}' external-squid 2>/dev/null | grep -qx true; then
    break
  fi
  sleep 1
done
sudo podman inspect --format '{{.State.Running}}' external-squid | grep -qx true
EOF
