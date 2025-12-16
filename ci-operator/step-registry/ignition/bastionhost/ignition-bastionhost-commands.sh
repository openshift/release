#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

workdir=`mktemp -d`

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
bastion_ignition_file="${workdir}/${CLUSTER_NAME}-bastion.ign"

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

# base ignition
cat > "${bastion_ignition_file}" << EOF
{
  "ignition": {
    "config": {},
    "security": {
      "tls": {}
    },
    "timeouts": {},
    "version": "3.0.0"
  },
  "passwd": {
    "users": [
      {
        "name": "core",
        "sshAuthorizedKeys": []
      }
    ]
  },
  "storage": {
    "files": [
    ],
    "directories": [
    ]
  },
  "systemd": {
    "units": [
      {
        "enabled": false,
        "mask": true,
        "name": "zincati.service"
      }
    ]
  }
}
EOF


# ----------------------------------------------------------------
# PROXY ignition
# /srv/squid/etc/passwords
# /srv/squid/etc/mime.conf
# /srv/squid/etc/squid.conf
# /srv/squid/log/
# /srv/squid/cache
# ----------------------------------------------------------------

# Some webesites (e.g: the backend of central ci registry) support
# dual-stack dns. When accessing these websites via proxy, if the
# proxy server does not have ipv6 outgoing capacity, the access
# probably timeout. Though the proxy configuration support failover,
# that would result in instablity for clients when the failover did
# not happen yet. So here make the proxy use ipv4 to resolve the
# dual-stack websites as the default behavior.
proxy_dns_config="dns_v4_first on"
if [[ "${IPSTACK}" == "dualstack" ]]; then
    # when no setting, ipv6 DNS is preferred in squid process
    proxy_dns_config=""
fi

## PROXY Config
cat > ${workdir}/squid.conf << EOF
auth_param basic program /usr/lib64/squid/basic_ncsa_auth /etc/squid/passwords
auth_param basic realm proxy

acl authenticated proxy_auth REQUIRED
acl CONNECT method CONNECT
http_access allow authenticated
http_port 3128
cache deny all
${proxy_dns_config}
EOF

## PROXY Service
cat > ${workdir}/squid.service << EOF
[Unit]
Description=OpenShift QE Squid Proxy Server
After=network.target syslog.target

[Service]
Type=simple
TimeoutStartSec=5m
ExecStartPre=-/usr/bin/podman rm "squid-proxy"

ExecStart=/usr/bin/podman run --name "squid-proxy" \
--net host \
-p 3128:3128 \
-p 3129:3129 \
-v /srv/squid/etc:/etc/squid:Z \
-v /srv/squid/cache:/var/spool/squid:Z \
-v /srv/squid/log:/var/log/squid:Z \
quay.io/openshifttest/squid-proxy:4.13-fc31

ExecReload=-/usr/bin/podman stop "squid-proxy"
ExecReload=-/usr/bin/podman rm "squid-proxy"
ExecStop=-/usr/bin/podman stop "squid-proxy"
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

if [[ "${CUSTOM_PROXY_CREDENTIAL}" == "true" ]]; then
    PROXY_CREDENTIAL_ARP1=$(< /var/run/vault/proxy/custom_proxy_creds_encrypted_apr1)
else
    PROXY_CREDENTIAL_ARP1=$(< /var/run/vault/proxy/proxy_creds_encrypted_apr1)
fi
PROXY_CREDENTIAL_CONTENT="$(echo -e ${PROXY_CREDENTIAL_ARP1} | base64 -w0)"
PROXY_CONFIG_CONTENT=$(cat ${workdir}/squid.conf | base64 -w0)
PROXY_SERVICE_CONTENT=$(sed ':a;N;$!ba;s/\n/\\n/g' ${workdir}/squid.service | sed 's/\"/\\"/g')

# proxy ignition
proxy_ignition_patch=$(mktemp)
cat > "${proxy_ignition_patch}" << EOF
{
  "storage": {
    "files": [
      {
        "path": "/srv/squid/etc/passwords",
        "contents": {
          "source": "data:text/plain;base64,${PROXY_CREDENTIAL_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/srv/squid/etc/squid.conf",
        "contents": {
          "source": "data:text/plain;base64,${PROXY_CONFIG_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/srv/squid/etc/mime.conf",
        "contents": {
          "source": "data:text/plain;base64,"
        },
        "mode": 420
      }
    ],
    "directories": [
      {
        "path": "/srv/squid/log",
        "mode": 493
      },
      {
        "path": "/srv/squid/cache",
        "mode": 493
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "contents": "${PROXY_SERVICE_CONTENT}",
        "enabled": true,
        "name": "squid.service"
      }
    ]
  }
}
EOF

# patch proxy setting to ignition
patch_ignition_file "${bastion_ignition_file}" "${proxy_ignition_patch}"
rm -f "${proxy_ignition_patch}"

# ----------------------------------------------------------------
# RSYNCD ignition
# /etc/rsyncd.conf
# ----------------------------------------------------------------
cat > ${workdir}/rsyncd.service << EOF
[Unit]
Description=rsyn daemon service
After=syslog.target network.target
ConditionPathExists=/etc/rsyncd.conf

[Service]
ExecStart=/usr/bin/rsync --daemon --no-detach
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

cat > ${workdir}/rsyncd.conf << EOF
pid file = /var/run/rsyncd.pid
lock file = /var/run/rsync.lock
log file = /var/log/rsync.log
port = 873

[tmp]
path = /tmp
comment = RSYNC FILES
read only = false
timeout = 300
EOF

RSYNCD_CONFIG_CONTENT=$(cat ${workdir}/rsyncd.conf | base64 -w0)
RSYNCD_SERVICE_CONTENT=$(sed ':a;N;$!ba;s/\n/\\n/g' ${workdir}/rsyncd.service | sed 's/\"/\\"/g')

# rsync ignition
rsyncd_ignition_patch=$(mktemp)
cat > "${rsyncd_ignition_patch}" << EOF
{
  "storage": {
    "files": [
      {
        "path": "/etc/rsyncd.conf",
        "overwrite": true,
        "contents": {
          "source": "data:text/plain;base64,${RSYNCD_CONFIG_CONTENT}"
        },
        "mode": 420
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "contents": "${RSYNCD_SERVICE_CONTENT}",
        "enabled": true,
        "name": "rsyncd.service"
      }
    ]
  }
}
EOF

patch_ignition_file "${bastion_ignition_file}" "${rsyncd_ignition_patch}"

rm -f "${rsyncd_ignition_patch}"


## ----------------------------------------------------------------
# MIRROR REGISTORY
# /opt/registry-$port/auth/htpasswd
# /opt/registry-$port/certs/domain.crt
# /opt/registry-$port/certs/domain.key
# /opt/registry-$port/data
# 
## ----------------------------------------------------------------

function gen_registry_service_file() {
  local port="$1"
  local output="$2"
  cat > "${output}" << EOF
[Unit]
Description=OpenShift POC HTTP for PXE Config
After=network.target syslog.target

[Service]
Type=simple
TimeoutStartSec=5m
ExecStartPre=-/usr/bin/podman rm "poc-registry-${port}"
ExecStartPre=/usr/bin/chcon -Rt container_file_t /opt/registry-${port}


ExecStart=/usr/bin/podman run --name poc-registry-${port} \
-p ${port}:${port} \
--net host \
-v /opt/registry-${port}/data:/var/lib/registry:z \
-v /opt/registry-${port}/auth:/auth \
-v /opt/registry-${port}/certs:/certs:z \
-v /opt/registry-${port}/config.yaml:/etc/distribution/config.yml \
quay.io/openshifttest/registry:3

ExecReload=-/usr/bin/podman stop "poc-registry-${port}"
ExecReload=-/usr/bin/podman rm "poc-registry-${port}"
ExecStop=-/usr/bin/podman stop "poc-registry-${port}"
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
}

function gen_registry_config_file() {
  local port="$1"
  local output="$2"
  cat > "${output}" << EOF
version: 0.1
log:
  fields:
    service: registry
http:
  addr: :${port}
  headers:
    X-Content-Type-Options: [nosniff]
  tls:
    certificate: /certs/domain.crt
    key: /certs/domain.key
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
auth:
  htpasswd:
    realm: Registry Realm
    path: /auth/htpasswd
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
EOF
}

REGISTRY_PASSWORD_CONTENT=$(cat "/var/run/vault/mirror-registry/registry_creds_encrypted_htpasswd" | base64 -w0)
if [[ "${SELF_MANAGED_REGISTRY_CERT}" == "true" ]]; then
    REGISTRY_CRT_CONTENT=$(cat "${CLUSTER_PROFILE_DIR}/mirror_registry_server_domain.crt" | base64 -w0)
    REGISTRY_KEY_CONTENT=$(cat "${CLUSTER_PROFILE_DIR}/mirror_registry_server_domain.pem" | base64 -w0)
else
    REGISTRY_CRT_CONTENT=$(cat "/var/run/vault/mirror-registry/server_domain.crt" | base64 -w0)
    REGISTRY_KEY_CONTENT=$(cat "/var/run/vault/mirror-registry/server_domain.pem" | base64 -w0)
fi

declare -a registry_ports=("5000" "6001" "6002")

for port in "${registry_ports[@]}"; do
  registry_service_file="${workdir}/registry_service_file_$port"
  registry_config_file="${workdir}/registry_config_file_$port"

  gen_registry_service_file $port "${registry_service_file}"
  gen_registry_config_file $port "${registry_config_file}"
done

# special custom configurations for individual registry register
patch_file=$(mktemp)

# patch proxy for 6001 quay.io
reg_quay_url=$(cat "/var/run/vault/mirror-registry/registry_quay_proxy.json" | jq -r '.url')
reg_quay_user=$(cat "/var/run/vault/mirror-registry/registry_quay_proxy.json" | jq -r '.user')
reg_quay_password=$(cat "/var/run/vault/mirror-registry/registry_quay_proxy.json" | jq -r '.password')
cat > "${patch_file}" << EOF
proxy:
  remoteurl: "${reg_quay_url}"
  username: "${reg_quay_user}"
  password: "${reg_quay_password}"
EOF
yq-go m -x -i "${workdir}/registry_config_file_6001" "${patch_file}"

# patch proxy for 6002 brew.registry.redhat.io
reg_brew_url=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.url')
reg_brew_user=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.user')
reg_brew_password=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.password')
cat > "${patch_file}" << EOF
proxy:
  remoteurl: "${reg_brew_url}"
  username: "${reg_brew_user}"
  password: "${reg_brew_password}"
EOF
yq-go m -x -i "${workdir}/registry_config_file_6002" "${patch_file}"

rm -f "${patch_file}"

for port in "${registry_ports[@]}"; do
  registry_service_file="${workdir}/registry_service_file_$port"
  registry_config_file="${workdir}/registry_config_file_$port"

  # adjust system unit content to ignition format
  #   replace [newline] with '\n', and replace '"' with '\"'
  #   https://stackoverflow.com/questions/1251999/how-can-i-replace-a-newline-n-using-sed
  REGISTRY_SERVICE_CONTENT=$(sed ':a;N;$!ba;s/\n/\\n/g' "${registry_service_file}" | sed 's/\"/\\"/g')
  REGISTRY_CONFIG_CONTENT=$(cat "${registry_config_file}" | base64 -w0)

  registry_ignition_patch=$(mktemp)
  cat > "${registry_ignition_patch}" << EOF
{
  "storage": {
    "files": [
      {
        "path": "/opt/registry-${port}/auth/htpasswd",
        "contents": {
          "source": "data:text/plain;base64,${REGISTRY_PASSWORD_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/opt/registry-${port}/certs/domain.crt",
        "contents": {
          "source": "data:text/plain;base64,${REGISTRY_CRT_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/opt/registry-${port}/certs/domain.key",
        "contents": {
          "source": "data:text/plain;base64,${REGISTRY_KEY_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/opt/registry-${port}/config.yaml",
        "contents": {
          "source": "data:text/plain;base64,${REGISTRY_CONFIG_CONTENT}"
        },
        "mode": 420
      }
    ],
    "directories": [
      {
        "path": "/opt/registry-${port}/data",
        "mode": 493
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "contents": "${REGISTRY_SERVICE_CONTENT}",
        "enabled": true,
        "name": "poc-registry-${port}.service"
      }
    ]
  }
}
EOF

  # patch registry setting to ignition
  patch_ignition_file "${bastion_ignition_file}" "${registry_ignition_patch}"
  rm -f "${registry_ignition_patch}"
done

# update ssh keys
tmp_keys_json=`mktemp`
tmp_file=`mktemp`
echo '[]' > "$tmp_keys_json"

ssh_pub_keys_file="${CLUSTER_PROFILE_DIR}/ssh-publickey"
readarray -t contents < "${ssh_pub_keys_file}"
for ssh_key_content in "${contents[@]}"; do
  jq --arg k "$ssh_key_content" '. += [$k]' < "${tmp_keys_json}" > "${tmp_file}"
  mv "${tmp_file}" "${tmp_keys_json}"
done

jq --argjson k "`jq '.| unique' "${tmp_keys_json}"`" '.passwd.users[0].sshAuthorizedKeys = $k' < "${bastion_ignition_file}" > "${tmp_file}"
mv "${tmp_file}" "${bastion_ignition_file}"

cp "${bastion_ignition_file}" "${SHARED_DIR}/${CLUSTER_NAME}-bastion.ign"
echo "Ignition file '${SHARED_DIR}/${CLUSTER_NAME}-bastion.ign' created"

rm -rf "${workdir}"
