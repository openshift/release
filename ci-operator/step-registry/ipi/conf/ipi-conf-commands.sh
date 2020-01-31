#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
cluster_name=${NAMESPACE}-${JOB_NAME_HASH}

out=/tmp/secret/install-config.yaml
mkdir "$(dirname "${out}")"

cluster_variant=
if [[ -e "${SHARED_DIR}/install-config-variant.txt" ]]; then
    cluster_variant=$(<"${SHARED_DIR}/install-config-variant.txt")
fi

function has_variant() {
    regex="(^|,)$1($|,)"
    if [[ $cluster_variant =~ $regex ]]; then
        return 0
    fi
    return 1
}

base_domain=
if [[ -e "${SHARED_DIR}/install-config-base-domain.txt" ]]; then
    base_domain=$(<"${SHARED_DIR}/install-config-base-domain.txt")
else
    case "${CLUSTER_TYPE}" in
    aws) base_domain=origin-ci-int-aws.dev.rhcloud.com;;
    azure) base_domain=ci.azure.devcluster.openshift.com;;
    gcp) base_domain=origin-ci-int-gce.dev.openshift.com;;
    *) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    esac
fi

echo "Installing from release ${RELEASE_IMAGE_LATEST}"

expiration_date=$(date -d '4 hours' --iso=minutes --utc)
ssh_pub_key=$(<"${cluster_profile}/ssh-publickey")
pull_secret=$(<"${cluster_profile}/pull-secret")

workers=3
if has_variant compact; then
    workers=0
fi

case "${CLUSTER_TYPE}" in
aws)
    case "$((RANDOM % 4))" in
    0) aws_region=us-east-1
       zone_1=us-east-1b
       zone_2=us-east-1c;;
    1) aws_region=us-east-2;;
    2) aws_region=us-west-1;;
    3) aws_region=us-west-2;;
    *) echo >&2 "invalid AWS region index"; exit 1;;
    esac
    echo "AWS region: ${aws_region} (zones: ${zone_1:-${aws_region}a} ${zone_2:-${aws_region}b})"
    master_type=null
    if has_variant xlarge; then
        master_type=m5.8xlarge
    elif has_variant large; then
        master_type=m5.4xlarge
    fi
    subnets="[]"
    if has_variant "shared-vpc"; then
        case "${aws_region}_$((RANDOM % 4))" in
        us-east-1_0) subnets="['subnet-030a88e6e97101ab2','subnet-0e07763243186cac5','subnet-02c5fea7482f804fb','subnet-0291499fd1718ee01','subnet-01c4667ad446c8337','subnet-025e9043c44114baa']";;
        us-east-1_1) subnets="['subnet-0170ee5ccdd7e7823','subnet-0d50cac95bebb5a6e','subnet-0094864467fc2e737','subnet-0daa3919d85296eb6','subnet-0ab1e11d3ed63cc97','subnet-07681ad7ce2b6c281']";;
        us-east-1_2) subnets="['subnet-00de9462cf29cd3d3','subnet-06595d2851257b4df','subnet-04bbfdd9ca1b67e74','subnet-096992ef7d807f6b4','subnet-0b3d7ba41fc6278b2','subnet-0b99293450e2edb13']";;
        us-east-1_3) subnets="['subnet-047f6294332aa3c1c','subnet-0c3bce80bbc2c8f1c','subnet-038c38c7d96364d7f','subnet-027a025e9d9db95ce','subnet-04d9008469025b101','subnet-02f75024b00b20a75']";;
        us-east-2_0) subnets="['subnet-0a568760cd74bf1d7','subnet-0320ee5b3bb78863e','subnet-015658a21d26e55b7','subnet-0c3ce64c4066f37c7','subnet-0d57b6b056e1ee8f6','subnet-0b118b86d1517483a']";;
        us-east-2_1) subnets="['subnet-0f6c106c48187d0a9','subnet-0d543986b85c9f106','subnet-05ef94f36de5ac8c4','subnet-031cdc26c71c66e83','subnet-0f1e0d62680e8b883','subnet-00e92f507a7cbd8ac']";;
        us-east-2_2) subnets="['subnet-0310771820ebb25c7','subnet-0396465c0cb089722','subnet-02e316495d39ce361','subnet-0c5bae9b575f1b9af','subnet-0b3de1f0336c54cfe','subnet-03f164174ccbc1c60']";;
        us-east-2_3) subnets="['subnet-045c43b4de0092f74','subnet-0a78d4ddcc6434061','subnet-0ed28342940ef5902','subnet-02229d912f99fc84f','subnet-0c9b3aaa6a1ad2030','subnet-0c93fb4760f95dbe4']";;
        us-west-1_0) subnets="['subnet-0919ede122e5d3e46','subnet-0cf9da97d102fff0d','subnet-000378d8042931770','subnet-0c8720acadbb099fc']";;
        us-west-1_1) subnets="['subnet-0129b0f0405beca97','subnet-073caab166af2207e','subnet-0f07362330db0ac66','subnet-007d6444690f88b33']";;
        us-west-1_2) subnets="['subnet-09affff50a1a3a9d0','subnet-0838fdfcbe4da6471','subnet-08b9c065aefd9b8de','subnet-027fcc48c429b9865']";;
        us-west-1_3) subnets="['subnet-0cd3dde41e1d187fe','subnet-0e78f426f8938df2d','subnet-03edeaf52c46468fa','subnet-096fb5b3a7da814c2']";;
        us-west-2_0) subnets="['subnet-04055d49cdf149e87','subnet-0b658a04c438ef43c','subnet-015f32caeff1bd736','subnet-0c96a7bb6ac78323c','subnet-0b7387e251953bdcf','subnet-0c19695d20ce05c60']";;
        us-west-2_1) subnets="['subnet-0483607b3e3c2514f','subnet-01139c6c5e3c1e28e','subnet-0cc9500f56a1df779','subnet-001b2c8acd2bac389','subnet-093f66b9d6deffafc','subnet-095b373699fb51212']";;
        us-west-2_2) subnets="['subnet-057c716b8953f834a','subnet-096f21593f10b44cb','subnet-0f281491881970222','subnet-0fec3730729e452d9','subnet-0381cfcc0183cb0ba','subnet-0f1189be41a2a2a2f']";;
        us-west-2_3) subnets="['subnet-072d00dcf02ad90a6','subnet-0ad913e4bd6ff53fa','subnet-09f90e069238e4105','subnet-064ecb1b01098ff35','subnet-068d9cdd93c0c66e6','subnet-0b7d1a5a6ae1d9adf']";;
        *) echo >&2 "invalid subnets index"; exit 1;;
        esac
        echo "Subnets : ${subnets}"
    fi
    cat > "${out}" << EOF
apiVersion: v1
baseDomain: ${base_domain}
metadata:
  name: ${cluster_name}
controlPlane:
  name: master
  replicas: 3
  platform:
    aws:
      type: ${master_type}
      zones:
      - ${zone_1:-${aws_region}a}
      - ${zone_2:-${aws_region}b}
compute:
- name: worker
  replicas: ${workers}
  platform:
    aws:
      type: m4.xlarge
      zones:
      - ${zone_1:-${aws_region}a}
      - ${zone_2:-${aws_region}b}
platform:
  aws:
    region: ${aws_region}
    userTags:
      expirationDate: ${expiration_date}
    subnets: ${subnets}
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF
;;
azure4)
    case $((RANDOM % 8)) in
    0) azure_region=centralus;;
    1) azure_region=centralus;;
    2) azure_region=centralus;;
    3) azure_region=centralus;;
    4) azure_region=centralus;;
    5) azure_region=eastus;;
    6) azure_region=eastus2;;
    7) azure_region=westus;;
    esac
    echo "Azure region: ${azure_region}"
    vnetrg=""
    vnetname=""
    ctrlsubnet=""
    computesubnet=""
    if has_variant shared-vpc; then
        vnetrg="os4-common"
        vnetname="do-not-delete-shared-vnet-${azure_region}"
        ctrlsubnet="subnet-1"
        computesubnet="subnet-2"
    fi
    cat > "${out}" << EOF
apiVersion: v1
baseDomain: ${base_domain}
metadata:
  name: ${cluster_name}
controlPlane:
  name: master
  replicas: 3
compute:
- name: worker
  replicas: ${workers}
platform:
  azure:
    baseDomainResourceGroupName: os4-common
    region: ${azure_region}
    networkResourceGroupName: ${vnetrg}
    virtualNetwork: ${vnetname}
    controlPlaneSubnet: ${ctrlsubnet}
    computeSubnet: ${computesubnet}
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF
;;
gcp)
    gcp_region=us-east1
    gcp_project=openshift-gce-devel-ci
    # HACK: try to "poke" the token endpoint before the test starts
    for i in $(seq 1 30); do
        code="$( curl -s -o /dev/null -w "%{http_code}" https://oauth2.googleapis.com/token -X POST -d '' || echo "Failed to POST https://oauth2.googleapis.com/token with $?" 1>&2)"
        if [[ "${code}" == "400" ]]; then
            break
        fi
        echo "error: Unable to resolve https://oauth2.googleapis.com/token: $code" 1>&2
        if [[ "${i}" == "30" ]]; then
            echo "error: Unable to resolve https://oauth2.googleapis.com/token within timeout, exiting" 1>&2
            exit 1
        fi
        sleep 1
    done
    network=""
    ctrlsubnet=""
    computesubnet=""
    if has_variant shared-vpc; then
        network="do-not-delete-shared-network"
        ctrlsubnet="do-not-delete-shared-master-subnet"
        computesubnet="do-not-delete-shared-worker-subnet"
    fi
    cat > "${out}" << EOF
apiVersion: v1
baseDomain: ${base_domain}
metadata:
  name: ${cluster_name}
controlPlane:
  name: master
  replicas: 3
compute:
- name: worker
  replicas: ${workers}
platform:
  gcp:
    projectID: ${gcp_project}
    region: ${gcp_region}
    network: ${network}
    controlPlaneSubnet: ${ctrlsubnet}
    computeSubnet: ${computesubnet}
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF
;;
*)
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1;;
esac

# TODO proxy variant
# TODO CLUSTER_NETWORK_TYPE / ovn variant
# TODO mirror variant
# TODO fips variant
# TODO CLUSTER_NETWORK_MANIFEST
