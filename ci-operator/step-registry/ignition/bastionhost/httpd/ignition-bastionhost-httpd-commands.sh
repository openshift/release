#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

workdir=`mktemp -d`

CLUSTER_NAME="${NAMESPACE}-${JOB_NAME_HASH}"
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

# httpd servcie
httpd_service_file="${workdir}/httpd_service_file"
cat > "${httpd_service_file}" << EOF
[Unit]
Description=HTTPD 2.4 Server
After=network.target syslog.target

[Service]
Type=simple
TimeoutStartSec=5m
ExecStartPre=-/usr/bin/podman rm "httpd-8080"
ExecStartPre=sh -c '/usr/bin/mkdir -p /var/www/html/; restorecon -r /var/www'

ExecStart=/usr/bin/podman run --name "httpd-8080" -p 8080:8080 -p 80:8080 -v /var/www/html/:/var/www/html/ quay.io/openshifttest/httpd-24@sha256:8e16b154e440efb7b09d4322b8cb76dace09aeb068a7dcab4a414ed8958c8c39

ExecReload=-/usr/bin/podman stop "httpd-8080"
ExecReload=-/usr/bin/podman rm "httpd-8080"
ExecStop=-/usr/bin/podman stop "httpd-8080"
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

HTTPD_SERVICE_CONTENT=$(sed ':a;N;$!ba;s/\n/\\n/g' "${httpd_service_file}" | sed 's/\"/\\"/g')

# httpd ignition

echo "Generate ignition config for fcos bastion host."
httpd_ignition_patch=$(mktemp)
cat > "${httpd_ignition_patch}" << EOF
{
  "systemd": {
    "units": [
      {
        "contents": "${HTTPD_SERVICE_CONTENT}",
        "enabled": true,
        "name": "httpd.service"
      }
    ]
  }
}
EOF
patch_ignition_file "${bastion_ignition_file}" "${httpd_ignition_patch}"
rm -rf "${workdir}"
