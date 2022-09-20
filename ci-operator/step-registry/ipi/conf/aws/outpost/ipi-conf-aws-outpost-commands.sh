#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

function join_by { local IFS="$1"; shift; echo "$*"; }

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=/tmp/install-config-sharednetwork.yaml.patch

REGION="${LEASED_RESOURCE}"


OUTPOST_ID=$(aws outposts list-outposts | jq -r .Outposts[0].OutpostId)
OUTPOST_AZ=$(aws outposts list-outposts | jq -r .Outposts[0].AvailabilityZone)
OUTPOST_ARN=$(aws outposts list-outposts | jq -r .Outposts[0].OutpostArn)
OUTPOST_INSTANCE_TYPE=$(aws outposts get-outpost-instance-types --outpost-id $OUTPOST_ID | jq -r .InstanceTypes[1].InstanceType)


CLUSTER_NAME="$(yq-go r "${CONFIG}" 'metadata.name')"

curl -L https://raw.githubusercontent.com/openshift/installer/master/upi/aws/cloudformation/01_vpc.yaml -o /tmp/01_vpc.yaml

# The above cloudformation template's max zones account is 3
if [[ "${ZONES_COUNT}" -gt 3 ]]
then
  ZONES_COUNT=3
fi

STACK_NAME="${CLUSTER_NAME}-vpc"
aws --region "${REGION}" cloudformation create-stack \
  --stack-name "${STACK_NAME}" \
  --template-body "$(cat /tmp/01_vpc.yaml)" \
  --tags "${TAGS}" \
  --parameters \
    "ParameterKey=AvailabilityZone,ParameterValue=${OUTPOST_AZ}" \
    "ParameterKey=OutpostArn,ParameterValue=${OUTPOST_ARN}" \
    "ParameterKey=VpcCidr,ParameterValue=172.0.0.0/16" \
    "ParameterKey=SubnetBits,ParameterValue=12" \
    "ParameterKey=AvailabilityZoneCount,ParameterValue=${ZONES_COUNT}" &

wait "$!"
echo "Created stack"

aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${STACK_NAME}" &
wait "$!"
echo "Waited for stack"

subnets="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" | jq -c '[.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetIds")).OutputValue | split(",")[]]' | sed "s/\"/'/g")"
echo "Subnets : ${subnets}"

# save stack information to ${SHARED_DIR} for deprovision step
echo "${STACK_NAME}" >> "${SHARED_DIR}/sharednetworkstackname"

# Generate working availability zones from the region
mapfile -t AVAILABILITY_ZONES < <(aws --region "${REGION}" ec2 describe-availability-zones | jq -r '.AvailabilityZones[] | select(.State == "available") | .ZoneName' | sort -u)
ZONES=("${AVAILABILITY_ZONES[@]:0:${ZONES_COUNT}}")
ZONES_STR="[ $(join_by , "${ZONES[@]}") ]"
echo "AWS region: ${REGION} (zones: ${ZONES_STR})"

cat > "${PATCH}" << EOF
controlPlane:
  platform:
    aws:
      zones: ${ZONES_STR}
compute:
- platform:
    aws:
      zones: ${ZONES_STR}
      type: $OUTPOST_INSTANCE_TYPE
      rootVolume:
        type: gp2
        size: 120
platform:
  aws:
    subnets: ${subnets}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"

cp $CONFIG "${CONFIG}.bkp"


PRV_SUBN=$(aws cloudformation describe-stacks --stack-name $STACK_NAME |jq -r '.Stacks |.[].Outputs|.[] |select(.OutputKey=="PrivateSubnetIds").OutputValue')

openshift-install --dir $SHARED_DIR create manifests

OUTPOST_PRV_SUBN=$(aws cloudformation describe-stacks --stack-name $STACK_NAME |jq -r '.Stacks |.[].Outputs|.[] |select(.OutputKey=="OutpostPrivateSubnetId").OutputValue')
sed -i "s/$PRV_SUBN/$OUTPOST_PRV_SUBN/"  $SHARED_DIR/openshift/99_openshift-cluster-api_worker-machineset-0.yaml

cat << _EOF > $SHARED_DIR/manifests/cluster-network-03-config.yml
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  defaultNetwork:
_EOF

if [[ "$(yq-go r -j ${CONFIG}.bkp | jq -r '.networking.networkType')" == "OpenShiftSDN" ]]; then
  echo '    openshiftSDNConfig:'  >> $SHARED_DIR/manifests/cluster-network-03-config.yml
  echo '      mtu: 1250'          >> $SHARED_DIR/manifests/cluster-network-03-config.yml
else
  echo '    ovnKubernetesConfig:' >> $SHARED_DIR/manifests/cluster-network-03-config.yml
  echo '      mtu: 1200'          >> $SHARED_DIR/manifests/cluster-network-03-config.yml
fi
