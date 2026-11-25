#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

workdir=`mktemp -d`

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
bastion_ignition_file="${SHARED_DIR}/${CLUSTER_NAME}-bastion.ign"

function patch_ignition_file()
{
  local base_ignition=$1
  local patch_ignition=$2
  t=$(mktemp)
  # jq deepmerge 
  # https://stackoverflow.com/questions/53661930/jq-recursively-merge-objects-and-concatenate-arrays
  jq -s 'def deepmerge(a;b):
  reduce b[] as $item (a;
    reduce ($item | keys_unsorted[]) as $key (.;
      $item[$key] as $val | ($val | type) as $type | .[$key] = if ($type == "object") then
        deepmerge({}; [if .[$key] == null then {} else .[$key] end, $val])
      elif ($type == "array") then
        (.[$key] + $val | unique)
      else
        $val
      end)
    );
  deepmerge({}; .)' "${base_ignition}" "${patch_ignition}" > "${t}"
  mv "${t}" "${base_ignition}"
  rm -f "${t}"
}

# HAProxy servcie
haproxy_service_file="${workdir}/haproxy_service_file"
cat > "${haproxy_service_file}" << EOF
[Unit]
Description=haproxy
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=0
ExecStartPre=-/bin/podman kill haproxy
ExecStartPre=-/bin/podman rm haproxy
ExecStartPre=/bin/podman pull quay.io/openshift/origin-haproxy-router
ExecStart=/bin/podman run --name haproxy \
  --net=host \
  --privileged \
  --entrypoint=/usr/sbin/haproxy \
  -v /etc/haproxy/haproxy.cfg:/var/lib/haproxy/conf/haproxy.cfg:Z \
  quay.io/openshift/origin-haproxy-router -f /var/lib/haproxy/conf/haproxy.cfg
ExecStop=/bin/podman rm -f haproxy

[Install]
WantedBy=multi-user.target
EOF

HAPROXY_SERVICE_CONTENT=$(sed ':a;N;$!ba;s/\n/\\n/g' "${haproxy_service_file}" | sed 's/\"/\\"/g')

# haproxy ignition
haproxy_ignition_patch=$(mktemp)
cat > "${haproxy_ignition_patch}" << EOF
{
  "systemd": {
    "units": [
      {
        "contents": "${HAPROXY_SERVICE_CONTENT}",
        "enabled": true,
        "name": "haproxy.service"
      }
    ]
  }
}
EOF

# patch haproxy setting to ignition
patch_ignition_file "${bastion_ignition_file}" "${haproxy_ignition_patch}"
rm -rf "${workdir}"
