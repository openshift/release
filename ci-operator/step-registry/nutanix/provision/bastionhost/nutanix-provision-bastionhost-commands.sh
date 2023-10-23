#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function upload_rhcos_image() {
   curl -X POST --header "Content-Type: application/json" \
      --header "Accept: application/json" \
      --header "Authorization: Basic ${ENCODED_CREDS}" \
      "https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/nutanix/v3/images" \
      -d @- <<EOF
{
  "spec": {
    "name": "${RHCOS_IMAGE_NAME}",
    "resources": {
      "image_type": "DISK_IMAGE",
      "source_uri": "${BASTION_RHCOS_URI}",
      "architecture": "X86_64",
      "source_options": {
        "allow_insecure_connection": false
      }
    },
    "description": "RHCOS image for bastion host"
  },
  "api_version": "3.1.0",
  "metadata": {
    "use_categories_mapping": false,
    "kind": "image",
    "spec_version": 0,
    "categories_mapping": {},
    "should_force_translate": true,
    "entity_version": "string",
    "categories": {},
    "name": "string"
  }
}
EOF
}

function get_image_id() {
   IMAGE_ID=$(curl -X POST --header "Content-Type: application/json" \
      --header "Accept: application/json" \
      --header "Authorization: Basic ${ENCODED_CREDS}" \
      "https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/nutanix/v3/images/list" \
      -d '{ "kind": "image","filter": "","length": 60,"offset": 0}' |
      jq -r '.entities[] | select(.spec.name == "'"${RHCOS_IMAGE_NAME}"'") | .metadata.uuid')
}

function launch_vm() {
   curl -X POST --header "Content-Type: application/json" \
      --header "Accept: application/json" \
      --header "Authorization: Basic ${ENCODED_CREDS}" \
      "https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/nutanix/v3/vms" \
      -d @- <<EOF
{
   "spec": {
      "name": "${bastion_name}",
      "resources": {
         "power_state": "ON",
         "num_vcpus_per_socket": 1,
         "num_sockets": 4,
         "memory_size_mib": 16384,
         "disk_list": [
            {
               "disk_size_mib": 100000,
               "device_properties": {
                  "device_type": "DISK",
                  "disk_address": {
                     "device_index": 0,
                     "adapter_type": "SCSI"
                  }
               },
               "data_source_reference": {
                  "kind": "image",
                  "uuid": "${IMAGE_ID}"
               }
            }
         ],
         "nic_list": [
            {
               "nic_type": "NORMAL_NIC",
               "is_connected": true,
               "ip_endpoint_list": [
                  {
                     "ip_type": "DHCP"
                  }
               ],
               "subnet_reference": {
                  "kind": "subnet",
                  "uuid": "${BASTION_SUBNET_UUID}"
               }
            }
         ],
         "guest_customization": {
            "cloud_init": {
               "user_data": "${bastion_ignition_base64}"
            },
            "is_overridable": false
         }
      },
      "cluster_reference": {
         "kind": "cluster",
         "uuid": ${PE_UUID}
      }
   },
   "api_version": "3.1.0",
   "metadata": {
      "kind": "vm"
   }
}
EOF
}

function get_vm_ip() {
   BASTION_VM_IP=$(curl -X POST --header "Content-Type: application/json" \
      --header "Accept: application/json" \
      --header "Authorization: Basic ${ENCODED_CREDS}" \
      "https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/nutanix/v3/vms/list" \
      -d '{ "kind": "vm","filter": "","length": 60,"offset": 0}' |
      jq -r '.entities[] | select(.spec.name == "'"${bastion_name}"'") | .spec.resources.nic_list[0].ip_endpoint_list[0].ip')
}

# shellcheck source=/dev/null
source "${SHARED_DIR}/nutanix_context.sh"

ENCODED_CREDS="$(echo -n "${NUTANIX_USERNAME}:${NUTANIX_PASSWORD}" | base64)"
RHCOS_IMAGE_NAME="${BASTION_RHCOS_URI##*/}"
get_image_id
if [ "${IMAGE_ID}" == "" ]; then
   echo "$(date -u --rfc-3339=seconds) - Upload bastion host rhcos image"
   upload_rhcos_image
   # wait rhcos image uploading ready, maxmium 5 minutes
   loop=10
   while [ ${loop} -gt 0 ]; do
      get_image_id
      if [ "${IMAGE_ID}" == "" ]; then
         echo "$(date -u --rfc-3339=seconds) - bastion rhcos image uploading is not ready yet"
         loop=$((loop - 1))
         sleep 30
      else
         break
      fi
   done
   if [ "${IMAGE_ID}" == "" ]; then
      echo "$(date -u --rfc-3339=seconds) - Failed to get bastion host rhcos image id"
      exit 1
   fi
fi

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
bastion_name="${CLUSTER_NAME}-bastion"
bastion_ignition_file="${SHARED_DIR}/${CLUSTER_NAME}-bastion.ign"
if [[ ! -f "${bastion_ignition_file}" ]]; then
   echo "'${bastion_ignition_file}' not found, abort." && exit 1
fi
bastion_ignition_base64=$(base64 -w0 <"${bastion_ignition_file}")
echo "$(date -u --rfc-3339=seconds) - Launch bastion host virtual machine"
launch_vm

# wait bastion host IP ready, maxmium 10 minutes
loop=10
while [ ${loop} -gt 0 ]; do
   get_vm_ip
   if [ "${BASTION_VM_IP}" == "" ]; then
      echo "$(date -u --rfc-3339=seconds) - bastion host IP is not ready yet"
      loop=$((loop - 1))
      sleep 60
   else
      break
   fi
done
if [ "${BASTION_VM_IP}" == "" ]; then
   echo "$(date -u --rfc-3339=seconds) - Failed to get host IP"
   exit 1
fi

echo "${bastion_name}" > "${SHARED_DIR}/bastion_name"
echo "Bastion host created."

#Create dns for bastion host
if [[ "${REGISTER_MIRROR_REGISTRY_DNS}" == "yes" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Creating bastion host DNS..."
  base_domain=$(<"${SHARED_DIR}"/basedomain.txt)
  export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/nutanix/.awscred
  export AWS_MAX_ATTEMPTS=50
  export AWS_RETRY_MODE=adaptive

  bastion_host_dns="${bastion_name}.${base_domain}"
  bastion_hosted_zone_id="$(aws route53 list-hosted-zones-by-name \
            --dns-name "${base_domain}" \
            --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${base_domain}.\`].Id" \
            --output text)"
  echo "${bastion_hosted_zone_id}" > "${SHARED_DIR}/bastion-hosted-zone.txt"

  dns_create_str=""
  dns_delete_str=""
  dns_target='"TTL": 60,"ResourceRecords": [{"Value": "'${BASTION_VM_IP}'"}]'
  upsert_str="{\"Action\": \"UPSERT\",\"ResourceRecordSet\": {\"Name\": \"${bastion_host_dns}.\",\"Type\": \"A\",$dns_target}}"
  delete_str="{\"Action\": \"DELETE\",\"ResourceRecordSet\": {\"Name\": \"${bastion_host_dns}.\",\"Type\": \"A\",$dns_target}}"
  dns_create_str="${upsert_str},${dns_create_str}"
  dns_delete_str="${delete_str},${dns_delete_str}"

  cat > "${SHARED_DIR}"/bastion-host-dns-create.json <<EOF
{"Comment": "Create public OpenShift DNS records for bastion host on vSphere","Changes": [${dns_create_str::-1}]}
EOF

  cat > "${SHARED_DIR}"/bastion-host-dns-delete.json <<EOF
{"Comment": "Delete public OpenShift DNS records for bastion host on vSphere","Changes": [${dns_delete_str::-1}]}
EOF

  id=$(aws route53 change-resource-record-sets --hosted-zone-id "$bastion_hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/bastion-host-dns-create.json --query '"ChangeInfo"."Id"' --output text)
  echo "Waiting for DNS records to sync..."
  aws route53 wait resource-record-sets-changed --id "$id"
  echo "DNS records created."

  MIRROR_REGISTRY_URL="${bastion_host_dns}:5000"
  echo "${MIRROR_REGISTRY_URL}" > "${SHARED_DIR}/mirror_registry_url"
fi

#Save bastion information
echo "${BASTION_VM_IP}" >"${SHARED_DIR}/bastion_private_address"
echo "core" >"${SHARED_DIR}/bastion_ssh_user"

proxy_credential=$(cat /var/run/vault/proxy/proxy_creds)
proxy_private_url="http://${proxy_credential}@${BASTION_VM_IP}:3128"
echo "${proxy_private_url}" > "${SHARED_DIR}/proxy_private_url"

# echo proxy IP to ${SHARED_DIR}/proxyip
echo "${BASTION_VM_IP}" > "${SHARED_DIR}/proxyip"

echo "Sleeping 5 mins, make sure that the bastion host is fully started."
sleep 300
