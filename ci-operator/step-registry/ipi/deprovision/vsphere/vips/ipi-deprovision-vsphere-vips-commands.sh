#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

tfvars_path="${CLUSTER_PROFILE_DIR}/secret.auto.tfvars"
cluster_name="${NAMESPACE}-${JOB_NAME_HASH}"
ipam_token=$(grep -oP 'ipam_token\s*=\s*"\K[^"]+' "${tfvars_path}")

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# FIXME: should this be using ${SHARED_DIR}/vips.txt ?
echo "Releasing IP addresses from IPAM server..."
for i in {0..1}
do
    curl "http://ipam.vmc.ci.openshift.org/api/removeHost.php?apiapp=address&apitoken=${ipam_token}&host=${cluster_name}-$i"
done
