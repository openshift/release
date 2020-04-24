#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
tfvars_path="${cluster_profile}/secret.auto.tfvars"
cluster_name="${NAMESPACE}-${JOB_NAME_HASH}"
ipam_token=$(grep -oP 'ipam_token="\K[^"]+' "${tfvars_path}")

export AWS_SHARED_CREDENTIALS_FILE="${cluster_profile}/.awscred"

# FIXME: should this be using ${SHARED_DIR}/vips.txt ?
echo "Releasing IP addresses from IPAM server..."
for i in {0..1}
do
    curl "http://139.178.89.254/api/removeHost.php?apiapp=address&apitoken=${ipam_token}&host=${cluster_name}-$i"
done
