#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CLUSTER_NAME="${NAMESPACE}-${JOB_NAME_HASH}"
NETWORK=${NETWORK:-}
IMAGE_ARGS=""
python3 --version 
export CLOUDSDK_PYTHON=python3

if [[ -z "${IMAGE_FAMILY}" ]] && [[ ! -z "${IMAGE_NAME}" ]] ; then
   IMAGE_ARGS="--image=${IMAGE_NAME}"
fi

if [[ ! -z "${IMAGE_FAMILY}" ]] && [[ -z "${IMAGE_NAME}" ]] ; then
   IMAGE_ARGS="--image-family=${IMAGE_FAMILY}"
fi

if [[ -z "${IMAGE_ARGS}" ]]; then
  echo "image info not correct"
  exit 1 
fi

workdir=`mktemp -d`

#####################################
#########Save Login As Script###########
#####################################
cat > "${SHARED_DIR}/login_script.sh" << EOF 
    #!/bin/sh
    ####################################
    ###############Log In################
    #####################################
    GOOGLE_PROJECT_ID="\$(< \${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
    export GCP_SHARED_CREDENTIALS_FILE="\${CLUSTER_PROFILE_DIR}/gce.json"
    sa_email=\$(jq -r .client_email \${GCP_SHARED_CREDENTIALS_FILE})
    if ! gcloud auth list | grep -E "\*\s+\${sa_email}"
    then                            
    gcloud auth activate-service-account --key-file="\${GCP_SHARED_CREDENTIALS_FILE}"
    gcloud config set project "\${GOOGLE_PROJECT_ID}"
    fi
    mkdir -p "\${HOME}"/.ssh
    chmod 0700 "\${HOME}"/.ssh                            
    cp "\${CLUSTER_PROFILE_DIR}"/ssh-privatekey "\${HOME}"/.ssh/google_compute_engine
    chmod 0600 "\${HOME}"/.ssh/google_compute_engine                           
    cp "\${CLUSTER_PROFILE_DIR}"/ssh-publickey "\${HOME}"/.ssh/google_compute_engine.pub                                                                                                         
    #####################################                                                                        
    #####################################                                                                        
EOF
chmod +x ${SHARED_DIR}/login_script.sh

#####################################
###############Log In################
#####################################

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

REGION="${LEASED_RESOURCE}"
echo "Using region: ${REGION}"

VPC_CONFIG="${SHARED_DIR}/customer_vpc_subnets.yaml"
if [[ -z "${NETWORK}" || -z "${CONTROL_PLANE_SUBNET}" ]]; then
  NETWORK=$(yq-go r "${VPC_CONFIG}" 'platform.gcp.network')
  CONTROL_PLANE_SUBNET=$(yq-go r "${VPC_CONFIG}" 'platform.gcp.controlPlaneSubnet')
fi
if [[ -z "${NETWORK}" || -z "${CONTROL_PLANE_SUBNET}" ]]; then
  echo "Could not find VPC network and control-plane subnet" && exit 1
fi
ZONE_0=$(gcloud compute regions describe ${REGION} --format=json | jq -r .zones[0] | cut -d "/" -f9)
MACHINE_TYPE="n2-standard-8"

#####################################
##########Create server_#############
#####################################

# we need to be able to tear down the proxy even if install fails
# cannot rely on presence of ${SHARED_DIR}/metadata.json
echo "${REGION}" >> "${SHARED_DIR}/region"

server_name="${CLUSTER_NAME}-buildhost"
gcloud compute instances create "${server_name}" \
  ${IMAGE_ARGS} \
  --image-project=${IMAGE_PROJECT} \
  --boot-disk-type pd-ssd \
  --boot-disk-size=200GB \
  --machine-type=${MACHINE_TYPE} \
  --metadata-from-file ssh-keys="${CLUSTER_PROFILE_DIR}/ssh-publickey" \
  --network=${NETWORK} \
  --subnet=${CONTROL_PLANE_SUBNET} \
  --zone=${ZONE_0} \
  --tags="${server_name}"

echo "Created Server instance"

if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  HOST_PROJECT="$(jq -r '.hostProject' "${SHARED_DIR}/xpn.json")"
  project_option="--project=${HOST_PROJECT}"
else
  project_option=""
fi
gcloud ${project_option} compute firewall-rules create "${server_name}-ingress-allow" \
  --network ${NETWORK} \
  --allow tcp:22 \
  --target-tags="${server_name}"
cat > "${SHARED_DIR}/destroy.sh" << EOF
gcloud compute instances delete -q "${server_name}" --zone=${ZONE_0}
gcloud ${project_option} compute firewall-rules delete -q "${server_name}-ingress-allow"
EOF

#####################################
#########Save Server Info###########
#####################################
echo "Instance ${server_name}"
echo "${server_name}" >> "${SHARED_DIR}/gcp-instance-ids.txt"

gcloud compute instances list --filter="name=${server_name}" \
  --zones "${ZONE_0}" --format json > "${workdir}/${server_name}.json"
server__private_ip="$(jq -r '.[].networkInterfaces[0].networkIP' ${workdir}/${server_name}.json)"
server__public_ip="$(jq -r '.[].networkInterfaces[0].accessConfigs[0].natIP' ${workdir}/${server_name}.json)"

if [ X"${server__public_ip}" == X"" ] || [ X"${server__private_ip}" == X"" ] ; then
    echo "Did not found public or internal IP!"
    exit 1
fi
echo "export IP=${server__public_ip}" > "${SHARED_DIR}/env"
echo "export PRIVATE_IP=${server__private_ip}" >> "${SHARED_DIR}/env"
echo "export ZONE=${ZONE_0}" >> "${SHARED_DIR}/env"
cat <<EOF >> "${SHARED_DIR}/env"
export SSHOPTS=(-o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR -i "\${CLUSTER_PROFILE_DIR}/ssh-privatekey")
EOF
