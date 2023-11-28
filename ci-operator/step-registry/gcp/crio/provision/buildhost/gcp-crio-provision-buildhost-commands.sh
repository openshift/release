#!/bin/bash

set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
NETWORK=${NETWORK:-}
IMAGE_ARGS=""
python3 --version
export CLOUDSDK_PYTHON=python3

if [[ -n "${IMAGE_NAME}" ]]; then
  	IMAGE_ARGS="--image=${IMAGE_NAME}"
elif [[ -n "${IMAGE_FAMILY}" ]]; then
  	IMAGE_ARGS="--image-family=${IMAGE_FAMILY}"
fi

if [[ -n "${IMAGE_ARGS}" ]] && [[ -n "${IMAGE_PROJECT}" ]]; then
  	IMAGE_ARGS="--image-project=${IMAGE_PROJECT} ${IMAGE_ARGS}"
fi

if [[ -z "${IMAGE_ARGS}" ]]; then
	echo "image info not correct"
	exit 1
fi

SSH_USER=deadbeef

ssh-keygen -C ${SSH_USER} -t ed25519 -f ${SHARED_DIR}/vpc-sshkey -q -N ""
chmod 0600 ${SHARED_DIR}/vpc-sshkey

#####################################
##############Initialize#############
#####################################

workdir=$(mktemp -d)
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

#####################################
#########Save Login As Script###########
#####################################
cat >"${SHARED_DIR}/login_script.sh" <<EOF
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
    chmod 0600 ${SHARED_DIR}/vpc-sshkey
    #####################################                                                                        
    #####################################                                                                        
EOF
chmod +x ${SHARED_DIR}/login_script.sh

#####################################
###############Log In################
#####################################

GOOGLE_PROJECT_ID="$(<${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"; then
	gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
	gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

REGION="${LEASED_RESOURCE}"
echo "Using region: ${REGION}"

VPC_CONFIG="${SHARED_DIR}/customer_vpc_subnets.yaml"
if [[ -z "${NETWORK}" || -z "${CONTROL_PLANE_SUBNET}" ]]; then
	NETWORK=$(/tmp/yq r "${VPC_CONFIG}" 'platform.gcp.network')
	CONTROL_PLANE_SUBNET=$(/tmp/yq r "${VPC_CONFIG}" 'platform.gcp.controlPlaneSubnet')
fi
if [[ -z "${NETWORK}" || -z "${CONTROL_PLANE_SUBNET}" ]]; then
	echo "Could not find VPC network and control-plane subnet" && exit 1
fi
ZONE_0=$(gcloud compute regions describe ${REGION} --format=json | jq -r .zones[0] | cut -d "/" -f9)

#####################################
##########Create server_#############
#####################################

# we need to be able to tear down the proxy even if install fails
# cannot rely on presence of ${SHARED_DIR}/metadata.json
echo "${REGION}" >>"${SHARED_DIR}/region"
server_name="${CLUSTER_NAME}-buildhost"

MACHINE_TYPE="n2-standard-8"
gcloud compute instances create "${server_name}" \
	${IMAGE_ARGS} \
	--boot-disk-type pd-ssd \
	--boot-disk-size=200GB \
	--machine-type=${MACHINE_TYPE} \
	--metadata ssh-keys="${SSH_USER}:$(cat ${SHARED_DIR}/vpc-sshkey.pub)" \
	--network=${NETWORK} \
	--subnet=${CONTROL_PLANE_SUBNET} \
	--zone=${ZONE_0} \
	--tags="${server_name}"

echo "Created Server instance"

gcloud compute firewall-rules create "${server_name}-ingress-allow" \
	--network ${NETWORK} \
	--allow tcp:22,icmp \
	--target-tags="${server_name}"
cat >"${SHARED_DIR}/destroy.sh" <<EOF
gcloud compute instances delete -q "${server_name}" --zone=${ZONE_0}
gcloud compute firewall-rules delete -q "${server_name}-ingress-allow"
EOF

#####################################
#########Save Server Info###########
#####################################
echo "Instance ${server_name}"
echo "${server_name}" >>"${SHARED_DIR}/gcp-instance-ids.txt"

gcloud compute instances list --filter="name=${server_name}" \
	--zones "${ZONE_0}" --format json >"${workdir}/${server_name}.json"
server__private_ip="$(jq -r '.[].networkInterfaces[0].networkIP' ${workdir}/${server_name}.json)"
server__public_ip="$(jq -r '.[].networkInterfaces[0].accessConfigs[0].natIP' ${workdir}/${server_name}.json)"

if [ X"${server__public_ip}" == X"" ] || [ X"${server__private_ip}" == X"" ]; then
	echo "Did not found public or internal IP!"
	exit 1
fi
echo "export IP=${server__public_ip}" >"${SHARED_DIR}/env"
echo "export PRIVATE_IP=${server__private_ip}" >>"${SHARED_DIR}/env"
echo "export SSH_USER=${SSH_USER}" >>"${SHARED_DIR}/env"
echo "export SSH_PRIVATE_KEY_FILE=${SHARED_DIR}/vpc-sshkey" >>"${SHARED_DIR}/env"
echo "export SSH_PUBLIC_KEY_FILE=${SHARED_DIR}/vpc-sshkey.pub" >>"${SHARED_DIR}/env"
echo "export ZONE=${ZONE_0}" >>"${SHARED_DIR}/env"
cat <<EOF >>"${SHARED_DIR}/env"
export SSHOPTS=(-l ${SSH_USER} -o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR -i "\${SHARED_DIR}/vpc-sshkey")
export PROJECT_ID=${GOOGLE_PROJECT_ID}
EOF
