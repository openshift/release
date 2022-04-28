#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function wait_public_dns() {
    echo "Wait public DNS - $1 take effect"
    local try=0 retries=10

    while [ X"$(dig +short $1)" == X"" ] && [ $try -lt $retries ]; do
        echo "$1 does not take effect yet on internet, waiting..."
        sleep 60
        try=$(expr $try + 1)
    done
    if [ X"$try" == X"$retries" ]; then
        echo "!!!!!!!!!!"
        echo "Something wrong, pls check your dns provider"
        return 4
    fi
    return 0

}

#####################################
##############Initialize#############
#####################################

workdir=`mktemp -d`

ssh_pub_keys_file="${CLUSTER_PROFILE_DIR}/ssh-publickey"

# dump out from 'openshift-install coreos print-stream-json' on 4.10.0-rc.1
bastion_source_vhd_uri="${BASTION_VHD_URI}"
bastion_name="${NAMESPACE}-${JOB_NAME_HASH}-bastion"

if [ -z "${RESOURCE_GROUP}" ]; then
  rg_file="${SHARED_DIR}/resouregroup"
  if [ -f "${rg_file}" ]; then
    bastion_rg=$(cat "${rg_file}")
  else
    echo "Did not find ${rg_file}!"
    exit 1
  fi
else
  bastion_rg="${RESOURCE_GROUP}"
fi

if [ -z "${VNET_NAME}" ]; then
  vnet_file="${SHARED_DIR}/customer_vnet_subnets.yaml"
  if [ -f "${vnet_file}" ]; then
    curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq
    bastion_vnet_name=$(/tmp/yq r ${vnet_file} 'platform.azure.virtualNetwork')
  else
    echo "Did not find ${vnet_file}!"
    exit 1
  fi
else
  bastion_vnet_name="${VNET_NAME}"
fi

#####################################
#######Create Config Ignition#######
#####################################
echo "Generate ignition config for bastion host."


## ----------------------------------------------------------------
## Generate ignition file for dynamic host
## ----------------------------------------------------------------

bastion_ignition_file="${workdir}/bastion.ign"

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

# base ignition content
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


## ----------------------------------------------------------------
# PROXY
## ----------------------------------------------------------------
proxy_config_file="${workdir}/proxy_config_file"
proxy_service_file="${workdir}/proxy_service_file"

## PROXY CONFIG
cat > "${proxy_config_file}" << EOF
auth_param basic program /usr/lib64/squid/basic_ncsa_auth /etc/squid/passwords
auth_param basic realm proxy

acl authenticated proxy_auth REQUIRED
acl CONNECT method CONNECT
http_access allow authenticated
http_port 3128
EOF

## PROXY Service
cat > "${proxy_service_file}" << EOF
[Unit]
Description=OpenShift QE Squid Proxy Server
After=network.target syslog.target

[Service]
Type=simple
TimeoutStartSec=5m
ExecStartPre=-/usr/bin/podman rm "squid-proxy"

ExecStart=/usr/bin/podman run   --name "squid-proxy" \
                                --net host \
                                -p 3128:3128 \
                                -p 3129:3129 \
                                -v /srv/squid/etc:/etc/squid:Z \
                                -v /srv/squid/cache:/var/spool/squid:Z \
                                -v /srv/squid/log:/var/log/squid:Z \
                                quay.io/crcont/squid

ExecReload=-/usr/bin/podman stop "squid-proxy"
ExecReload=-/usr/bin/podman rm "squid-proxy"
ExecStop=-/usr/bin/podman stop "squid-proxy"
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

PROXY_CREDENTIAL_ARP1=$(< /var/run/vault/proxy/proxy_creds_encrypted_apr1)
PROXY_CREDENTIAL_CONTENT="$(echo -e ${PROXY_CREDENTIAL_ARP1} | base64 -w0)"
PROXY_CONFIG_CONTENT=$(cat ${proxy_config_file} | base64 -w0)
PROXY_SERVICE_CONTENT=$(sed ':a;N;$!ba;s/\n/\\n/g' ${proxy_service_file} | sed 's/\"/\\"/g')

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
        "name": "squid-proxy.service"
      }
    ]
  }
}
EOF

# patch proxy setting to ignition
patch_ignition_file "${bastion_ignition_file}" "${proxy_ignition_patch}"
rm -f "${proxy_ignition_patch}"



## ----------------------------------------------------------------
# MIRROR REGISTORY
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


ExecStart=/usr/bin/podman run   --name poc-registry-${port} \
                                -p ${port}:${port} \
                                --net host \
                                -v /opt/registry-${port}/data:/var/lib/registry:z \
                                -v /opt/registry-${port}/auth:/auth \
                                -v /opt/registry-${port}/certs:/certs:z \
                                -v /opt/registry-${port}/config.yaml:/etc/docker/registry/config.yml \
                                registry:2

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
    rootdirectory: /opt/registry-${port}
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
REGISTRY_CRT_CONTENT=$(cat "/var/run/vault/mirror-registry/server_domain.crt" | base64 -w0)
REGISTRY_KEY_CONTENT=$(cat "/var/run/vault/mirror-registry/server_domain.pem" | base64 -w0)

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
reg_quay_url=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.url')
reg_quay_user=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.user')
reg_quay_password=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.password')
cat > "${patch_file}" << EOF
proxy:
  remoteurl: "${reg_quay_url}"
  username: "${reg_quay_user}"
  password: "${reg_quay_password}"
EOF
/tmp/yq m -x -i "${workdir}/registry_config_file_6001" "${patch_file}"

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
/tmp/yq m -x -i "${workdir}/registry_config_file_6002" "${patch_file}"

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

  # patch proxy setting to ignition
  patch_ignition_file "${bastion_ignition_file}" "${registry_ignition_patch}"
  rm -f "${registry_ignition_patch}"
done

# update ssh keys
tmp_keys_json=`mktemp`
tmp_file=`mktemp`
echo '[]' > "$tmp_keys_json"

readarray -t contents < "${ssh_pub_keys_file}"
for ssh_key_content in "${contents[@]}"; do
  jq --arg k "$ssh_key_content" '. += [$k]' < "${tmp_keys_json}" > "${tmp_file}"
  mv "${tmp_file}" "${tmp_keys_json}"
done

jq --argjson k "`jq '.| unique' "${tmp_keys_json}"`" '.passwd.users[0].sshAuthorizedKeys = $k' < "${bastion_ignition_file}" > "${tmp_file}"
mv "${tmp_file}" "${bastion_ignition_file}"

echo "Ignition file ${bastion_ignition_file} created"


#####################################
###############Log In################
#####################################
# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

#####################################
##########Create Bastion#############
#####################################

echo "azure vhd uri: ${bastion_source_vhd_uri}"

vhd_data=${bastion_ignition_file}

echo "Create a Storage Account for bastion vhd"
# 'account_name' must have length less than 24, so hardcode the basion sa name
sa_name_prefix=$(echo "${NAMESPACE}" | sed "s/ci-op-//" | sed 's/[-_]//g')
sa_name="${sa_name_prefix}${JOB_NAME_HASH}basa"
run_command "az storage account create -g ${bastion_rg} --name ${sa_name} --kind Storage --sku Standard_LRS" &&
account_key=$(az storage account keys list -g ${bastion_rg} --account-name ${sa_name} --query "[0].value" -o tsv) || exit 3

echo "Copy bastion vhd from public blob URI to the bastion Storage Account"
storage_contnainer="${bastion_name}vhd"
vhd_name=$(basename "${bastion_source_vhd_uri}")
status="unknown"
run_command "az storage container create --name ${storage_contnainer} --account-name ${sa_name}" &&
run_command "az storage blob copy start --account-name ${sa_name} --account-key ${account_key} --destination-blob ${vhd_name} --destination-container ${storage_contnainer} --source-uri '${bastion_source_vhd_uri}'" || exit 2
try=0 retries=15 interval=60
while [ X"${status}" != X"success" ] && [ $try -lt $retries ]; do
    echo "check copy complete, ${try} try..."
    cmd="az storage blob show --container-name ${storage_contnainer} --name '${vhd_name}' --account-name ${sa_name} --account-key ${account_key} -o tsv --query properties.copy.status"
    echo "Command: $cmd"
    status=$(eval "$cmd")
    echo "Status: $status"
    sleep $interval
    try=$(expr $try + 1)
done
if [ X"$status" != X"success" ]; then
    echo  "Something wrong, copy timeout or failed!"
    exit 2
fi
vhd_blob_url=$(az storage blob url --account-name ${sa_name} --account-key ${account_key} -c ${storage_contnainer} -n ${vhd_name} -o tsv)

echo "Deploy the bastion image from bastion vhd"
run_command "az image create --resource-group ${bastion_rg} --name '${bastion_name}-image' --source ${vhd_blob_url} --os-type Linux --storage-sku Standard_LRS" || exit 2
bastion_image_id=$(az image show --resource-group ${bastion_rg} --name "${bastion_name}-image" | jq -r '.id')

echo "Create bastion subnet"
open_port="22 3128 3129 5000" bastion_nsg="${bastion_name}-nsg" bastion_subnet="${bastion_name}Subnet"
run_command "az network nsg create -g ${bastion_rg} -n ${bastion_nsg}" &&
run_command "az network nsg rule create -g ${bastion_rg} --nsg-name '${bastion_nsg}' -n '${bastion_name}-allow' --priority 1000 --access Allow --source-port-ranges '*' --destination-port-ranges ${open_port}" &&
#subnet cidr for int service is hard code, it should be a sub rang of the whole VNet cidr, and not conflicts with master subnet and worker subnet
bastion_subnet_cidr="10.0.99.0/24"
vnet_subnet_address_parameter="--address-prefixes ${bastion_subnet_cidr}"
run_command "az network vnet subnet create -g ${bastion_rg} --vnet-name ${bastion_vnet_name} -n ${bastion_subnet} ${vnet_subnet_address_parameter} --network-security-group ${bastion_nsg}" || exit 2

echo "Create bastion vm"
bastion_ignition_file="${vhd_data}"
run_command "az vm create --resource-group ${bastion_rg} --name ${bastion_name} --admin-username core --admin-password 'NotActuallyApplied!' --image '${bastion_image_id}' --os-disk-size-gb 99 --subnet ${bastion_subnet} --vnet-name ${bastion_vnet_name} --nsg '' --size 'Standard_DS1_v2' --debug --custom-data '${bastion_ignition_file}'" || exit 2

bastion_private_ip=$(az vm list-ip-addresses --name ${bastion_name} --resource-group ${bastion_rg} | jq -r ".[].virtualMachine.network.privateIpAddresses[]") &&
bastion_public_ip=$(az vm list-ip-addresses --name ${bastion_name} --resource-group ${bastion_rg} | jq -r ".[].virtualMachine.network.publicIpAddresses[].ipAddress") || exit 2
if [ X"${bastion_public_ip}" == X"" ] || [ X"${bastion_private_ip}" == X"" ] ; then
    echo "Did not found public or internal IP!"
    exit 1
fi

#####################################
####Register mirror registry DNS#####
#####################################
if [[ "${REGISTER_MIRROR_REGISTRY_DNS}" == "yes" ]]; then
    mirror_registry_host="${bastion_name}.mirror-registry"
    mirror_registry_dns="${mirror_registry_host}.${BASE_DOMAIN}"

    echo "Adding private DNS record for mirror registry"
    private_zone="mirror-registry.${BASE_DOMAIN}"
    dns_vnet_link_name="${bastion_name}-pvz-vnet-link"
    run_command "az network private-dns zone create -g ${bastion_rg} -n ${private_zone}" &&
    run_command "az network private-dns record-set a add-record -g ${bastion_rg} -z ${private_zone} -n ${bastion_name} -a ${bastion_private_ip}" &&
    run_command "az network private-dns link vnet create --name '${dns_vnet_link_name}' --registration-enabled false --resource-group ${bastion_rg} --virtual-network ${bastion_vnet_name} --zone-name ${private_zone}" || exit 2

    echo "Adding public DNS record for mirror registry"
    cmd="az network dns record-set a add-record -g ${BASE_RESOURCE_GROUP} -z ${BASE_DOMAIN} -n ${mirror_registry_host} -a ${bastion_public_ip}"
    run_command "${cmd}" &&
    echo "az network dns record-set a remove-record -g ${BASE_RESOURCE_GROUP} -z ${BASE_DOMAIN} -n ${mirror_registry_host} -a ${bastion_public_ip}" >>"${SHARED_DIR}/remove_resources_by_cli.sh"
    wait_public_dns "${mirror_registry_dns}" || exit 2

    # save mirror registry dns info
    echo "${mirror_registry_dns}:5000" > "${SHARED_DIR}/mirror_registry_url"
fi

#####################################
#########Save Bastion Info###########
#####################################
echo ${bastion_public_ip} > "${SHARED_DIR}/bastion_public_address"
echo ${bastion_private_ip} > "${SHARED_DIR}/bastion_private_address"
echo "core" > "${SHARED_DIR}/bastion_ssh_user"

proxy_credential=$(cat /var/run/vault/proxy/proxy_creds)
proxy_public_url="http://${proxy_credential}@${bastion_public_ip}:3128"
proxy_private_url="http://${proxy_credential}@${bastion_private_ip}:3128"
echo "${proxy_public_url}" > "${SHARED_DIR}/proxy_public_url"
echo "${proxy_private_url}" > "${SHARED_DIR}/proxy_private_url"

# echo proxy IP to ${SHARED_DIR}/proxyip
echo "${bastion_public_ip}" > "${SHARED_DIR}/proxyip"

#####################################
##############Clean Up###############
#####################################
rm -rf "${workdir}"
