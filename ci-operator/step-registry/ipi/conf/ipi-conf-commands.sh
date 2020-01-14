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
        us-east-2_0) subnets="['subnet-0faf6d16c378ee7a7','subnet-0e104572db1b7d092','subnet-014ca96c04f36adec','subnet-0ea06057dceadfe8e','subnet-0689efe5e1f9f4212','subnet-0d36bb8edbcb3d916']";;
        us-east-2_1) subnets="['subnet-085787cc4b80b84b2','subnet-09dfbf66e8f6e5b50','subnet-0db5d90ff3087444e','subnet-047f15f2a0210fbe0','subnet-0bf13f041c4233849','subnet-0e2a5320549e289d8']";;
        us-east-2_2) subnets="['subnet-07d59b122f7a76f67','subnet-0d1a413c66cd59a3b','subnet-020df1de666b06b20','subnet-0ce9183380508d88d','subnet-04c83a79a1913824c','subnet-0d97ed1a54b1e9235']";;
        us-east-2_3) subnets="['subnet-0d689957169836114','subnet-081c5c0c7bc351205','subnet-023b79f57b84894e5','subnet-070c0b96148b58787','subnet-0c693d11c33437345','subnet-0249c4ec2d6509b4e']";;
        us-west-1_0) subnets="['subnet-0b0a3190ff0b05fb0','subnet-038719a99ae7f208c','subnet-0afc43ade6ca7f8e0','subnet-0df272b93eb3d79a5']";;
        us-west-1_1) subnets="['subnet-070d5f1a70aa7b2ad','subnet-0e371618c77a58409','subnet-046cbad6141e391ba','subnet-0528b85478ef9d2b5']";;
        us-west-1_2) subnets="['subnet-0a51561b99949d3c4','subnet-0de96f5675188f16f','subnet-05d1cbeccfb032e31','subnet-01e489eab26e95ec9']";;
        us-west-1_3) subnets="['subnet-0029d43cd2d22bfe4','subnet-0b5476fddae459d10','subnet-0955a46cb4b379c91','subnet-04e3dae5b3fdcbe61']";;
        us-west-2_0) subnets="['subnet-0a1956a6a6babc86b','subnet-07252d4a4737ec97e','subnet-00bcec6286b15a024','subnet-0f979e13d715cc03a','subnet-02e3b436e780363c5','subnet-02f0597dc582d3bde']";;
        us-west-2_1) subnets="['subnet-0e2979f62a537ab59','subnet-060b22e9f90846c58','subnet-0c61f833b2a4caa2a','subnet-022d5d9affc6a2241','subnet-02c903aa40cf463ef','subnet-0db7df4231255086d']";;
        us-west-2_2) subnets="['subnet-0d9b5481442b7d212','subnet-07795ec1097c5e34c','subnet-000d265d2bf4729f3','subnet-0d419e59ee340211c','subnet-0c8027d8d9794d822','subnet-05a19cfee3f602c7e']";;
        us-west-2_3) subnets="['subnet-08c871a474ab034cc','subnet-0fe9e5f0d33e16eb0','subnet-0731dfd7678a5bac8','subnet-0d476b24170ac5942','subnet-0f0da17f8581745e6','subnet-0842d7a0250595e13']";;
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
