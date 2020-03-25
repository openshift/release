#!/bin/bash

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
tfvars_path=/var/run/secrets/ci.openshift.io/cluster-profile/secret.auto.tfvars
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)
cluster_name=${NAMESPACE}-${JOB_NAME_HASH}
ipam_token=$(grep -oP 'ipam_token="\K[^"]+' ${tfvars_path})

export AWS_SHARED_CREDENTIALS_FILE=${cluster_profile}/.awscred 

echo "Deprovisioning cluster ..."
cp -ar "${SHARED_DIR}" /tmp/installer
openshift-install --dir /tmp/installer destroy cluster
cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}/.openshift_install.deprovision.log"

hosted_zone_id="$(aws route53 list-hosted-zones-by-name \
            --dns-name "${base_domain}" \
            --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${base_domain}.\`].Id" \
            --output text)"

echo "Releasing IP addresses from IPAM server..."
for i in {0..2}
do
    curl -s "http://139.178.89.254/api/removeHost.php?apiapp=address&apitoken=${ipam_token}&host=${cluster_name}-$i"
done

echo "Deleting Route53 DNS records..."
aws route53 change-resource-record-sets --hosted-zone-id "$hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/dns-delete.json
