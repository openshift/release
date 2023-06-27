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

# tang servcie
tang_service_file="${workdir}/tang_service_file"
cat > "${tang_service_file}" << EOF
[Unit]
Description=Tang Server
After=network.target syslog.target

[Service]
Type=simple
TimeoutStartSec=5m
ExecStartPre=-/usr/bin/podman rm "tang"
ExecStartPre=-/usr/bin/podman pull registry.redhat.io/rhel8/tang --authfile /etc/pull-secret.json
ExecStartPre=/usr/bin/chcon -Rt container_file_t /var/db/tang

ExecStart=/usr/bin/podman run --name "tang" -p 7500:8080 -v /var/db/tang:/var/db/tang  registry.redhat.io/rhel8/tang

ExecReload=-/usr/bin/podman stop "tang"
ExecReload=-/usr/bin/podman rm "tang"
ExecStop=-/usr/bin/podman stop "tang"
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

TANG_SERVICE_CONTENT=$(sed ':a;N;$!ba;s/\n/\\n/g' "${tang_service_file}" | sed 's/\"/\\"/g')

PULL_SECRET=$(base64 -w0 < "${CLUSTER_PROFILE_DIR}/pull-secret")

# tang ignition
tang_ignition_patch=$(mktemp)
cat > "${tang_ignition_patch}" << EOF
{
  "storage": {
    "files": [
      {
        "path": "/etc/pull-secret.json",
        "contents": {
          "source": "data:text/plain;base64,${PULL_SECRET}"
        },
        "mode": 420
      }
    ],
    "directories": [
      {
        "path": "/var/db/tang",
        "mode": 493
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "contents": "${TANG_SERVICE_CONTENT}",
        "enabled": true,
        "name": "tang.service"
      }
    ]
  }
}
EOF

# patch tang setting to ignition
patch_ignition_file "${bastion_ignition_file}" "${tang_ignition_patch}"
rm -rf "${workdir}"
