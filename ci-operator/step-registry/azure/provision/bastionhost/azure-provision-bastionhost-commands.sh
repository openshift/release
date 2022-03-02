#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

#####################################
##############Initialize#############
#####################################

workdir=`mktemp -d`

bastion_ignition_file="${workdir}/bastion.ign"
ssh_pub_keys_file="/var/run/vault/qe-ssh-key/public_key"
reg_cert_file="/var/run/vault/qe-mirror-registry/server_domain.crt"
reg_key_file="/var/run/vault/qe-mirror-registry/server_domain.pem"
src_proxy_creds_file="/var/run/vault/qe-proxy/proxy_creds"
src_proxy_creds_encrypted_file="/var/run/vault/qe-proxy/proxy_creds_encrypted_apr1"
src_registry_creds_encrypted_file="/var/run/vault/qe-mirror-registry/registry_creds_encrypted_htpasswd"

# dump out from 'openshift-install coreos print-stream-json' on 4.10.0-rc.1
vhd_uri=https://rhcos.blob.core.windows.net/imagebucket/rhcos-410.84.202201251210-0-azure.x86_64.vhd
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
# PROXY
# /srv/squid/etc/passwords
# /srv/squid/etc/mime.conf
# /srv/squid/etc/squid.conf
# /srv/squid/log/
# /srv/squid/cache
## ----------------------------------------------------------------

proxy_password_file="${workdir}/proxy_password_file"
proxy_config_file="${workdir}/proxy_config_file"
proxy_service_file="${workdir}/proxy_service_file"
cat "${src_proxy_creds_encrypted_file}" > "${proxy_password_file}"

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

## ----------------------------------------------------------------
# MIRROR REGISTORY
# /opt/registry/auth/htpasswd
# /opt/registry/certs/domain.crt
# /opt/registry/certs/domain.key
# /opt/registry/data
# 
## ----------------------------------------------------------------

## REGISTRY PASSWORD
registry_password_file="${workdir}/registry_password_file"
registry_service_file="${workdir}/registry_service_file"
cat "${src_registry_creds_encrypted_file}" > "${registry_password_file}"

cat > "${registry_service_file}" << EOF
[Unit]
Description=OpenShift POC HTTP for PXE Config
After=network.target syslog.target

[Service]
Type=simple
TimeoutStartSec=5m
ExecStartPre=-/usr/bin/podman rm "poc-registry"
ExecStartPre=/usr/bin/chcon -Rt container_file_t /opt/registry

ExecStart=/usr/bin/podman run   --name poc-registry -p 5000:5000 \
                                --net host \
                                -v /opt/registry/data:/var/lib/registry:z \
                                -v /opt/registry/auth:/auth \
                                -e "REGISTRY_AUTH=htpasswd" \
                                -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
                                -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
                                -v /opt/registry/certs:/certs:z \
                                -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt \
                                -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key \
                                registry:2

ExecReload=-/usr/bin/podman stop "poc-registry"
ExecReload=-/usr/bin/podman rm "poc-registry"
ExecStop=-/usr/bin/podman stop "poc-registry"
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF



# ## ----------------------------------------------------------------
# # DISABLE AUTO UPDATE
# # /etc/zincati/config.d/90-disable-auto-updates.toml
# ## ----------------------------------------------------------------
# zincati_config="${workdir}/zincati_config"
# cat > "${zincati_config}" << EOF
# [updates]
# enabled = false
# EOF


## ----------------------------------------------------------------
# IGNITION
## ----------------------------------------------------------------

PROXY_PASSWORD_CONTENT=$(cat "${proxy_password_file}" | base64 -w0)
PROXY_CONFIG_CONTENT=$(cat "${proxy_config_file}" | base64 -w0)

REGISTRY_PASSWORD_CONTENT=$(cat "${registry_password_file}" | base64 -w0)
REGISTRY_KEY_CONTENT=$(cat "${reg_key_file}" | base64 -w0)
REGISTRY_CRT_CONTENT=$(cat "${reg_cert_file}" | base64 -w0)

# adjust system unit content to ignition format
#   replace [newline] with '\n', and replace '"' with '\"'
#   https://stackoverflow.com/questions/1251999/how-can-i-replace-a-newline-n-using-sed
PROXY_SERVICE_CONTENT=$(sed ':a;N;$!ba;s/\n/\\n/g' "${proxy_service_file}" | sed 's/\"/\\"/g')
REGISTRY_SERVICE_CONTENT=$(sed ':a;N;$!ba;s/\n/\\n/g' "${registry_service_file}" | sed 's/\"/\\"/g')

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
      {
        "path": "/srv/squid/etc/passwords",
        "contents": {
          "source": "data:text/plain;base64,${PROXY_PASSWORD_CONTENT}"
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
      },
      {
        "path": "/opt/registry/auth/htpasswd",
        "contents": {
          "source": "data:text/plain;base64,${REGISTRY_PASSWORD_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/opt/registry/certs/domain.crt",
        "contents": {
          "source": "data:text/plain;base64,${REGISTRY_CRT_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/opt/registry/certs/domain.key",
        "contents": {
          "source": "data:text/plain;base64,${REGISTRY_KEY_CONTENT}"
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
      },
      {
        "path": "/opt/registry/data",
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
      },
      {
        "contents": "${REGISTRY_SERVICE_CONTENT}",
        "enabled": true,
        "name": "poc-registry.service"
      },
      {
        "enabled": false,
        "mask": true,
        "name": "zincati.service"
      }
    ]
  }
}
EOF

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
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

#####################################
##########Create Bastion#############
#####################################

echo "azure vhd uri: ${vhd_uri}"

vhd_data=${bastion_ignition_file}

echo "Create a Storage Account for bastion vhd"
# 'account_name' must have length less than 24, so hardcode the basion sa name
sa_name_prefix=$(echo "${NAMESPACE}" | sed "s/ci-op-//" | sed 's/[-_]//g')
sa_name="${sa_name_prefix}${JOB_NAME_HASH}basa"
run_command "az storage account create -g ${bastion_rg} --name ${sa_name} --kind Storage --sku Standard_LRS" &&
account_key=$(az storage account keys list -g ${bastion_rg} --account-name ${sa_name} --query "[0].value" -o tsv) || exit 3

echo "Copy bastion vhd from public blob URI to the bastion Storage Account"
storage_contnainer="${bastion_name}vhd"
bastion_source_vhd_uri="${vhd_uri}"
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

#####################################
#########Save Bastion Info###########
#####################################
bastion_internal_ip=$(az vm list-ip-addresses --name ${bastion_name} --resource-group ${bastion_rg} | jq -r ".[].virtualMachine.network.privateIpAddresses[]") &&
bastion_public_ip=$(az vm list-ip-addresses --name ${bastion_name} --resource-group ${bastion_rg} | jq -r ".[].virtualMachine.network.publicIpAddresses[].ipAddress") || exit 2
if [ X"$bastion_public_ip" == X"" ] || [ X"$bastion_internal_ip" == X"" ] ; then
    echo "Did not found public or internal IP!"
    exit 1
fi

proxy_credential=$(cat "${src_proxy_creds_file}")
PUBLIC_PROXY_URL="http://${proxy_credential}@${bastion_public_ip}:3128"
INTERNAL_PROXY_URL="http://${proxy_credential}@${bastion_internal_ip}:3128"


echo "${INTERNAL_PROXY_URL}" > "${SHARED_DIR}/internal_proxy_url"
echo "${PUBLIC_PROXY_URL}" > "${SHARED_DIR}/public_proxy_url"

#####################################
##############Clean Up###############
#####################################
rm -rf "${workdir}"
