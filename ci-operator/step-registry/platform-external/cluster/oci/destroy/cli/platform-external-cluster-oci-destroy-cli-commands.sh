#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

source "${SHARED_DIR}/infra_resources.env"

export OCI_CLI_CONFIG_FILE=/var/run/vault/opct-splat/opct-oci-splat-user-config
function upi_conf_provider() {
    mkdir -p $HOME/.oci
    ln -svf $OCI_CLI_CONFIG_FILE $HOME/.oci/config
}
upi_conf_provider

# Compute
## Clean up instances
oci compute instance terminate --force \
  --instance-id $INSTANCE_ID_BOOTSTRAP

oci compute-management instance-pool terminate --force \
  --instance-pool-id $INSTANCE_POOL_ID_CMP \
    --wait-for-state TERMINATED
oci compute-management instance-configuration delete --force \
  --instance-configuration-id $INSTANCE_CONFIG_ID_CMP

oci compute-management instance-pool terminate --force \
  --instance-pool-id $INSTANCE_POOL_ID_CPL \
  --wait-for-state TERMINATED
oci compute-management instance-configuration delete --force \
  --instance-configuration-id $INSTANCE_CONFIG_ID_CPL

## Custom image
oci compute image delete --force --image-id ${IMAGE_ID}

# IAM
## Remove policy
oci iam policy delete --force \
  --policy-id "$(oci iam policy list \
    --compartment-id "$COMPARTMENT_ID_OPENSHIFT" \
    --name "${POLICY_NAME}" | jq -r '.data[0].id')" \
  --wait-for-state DELETED

## Remove dynamic group
oci iam dynamic-group delete --force \
  --dynamic-group-id "$(oci iam dynamic-group list \
    --name "$DYNAMIC_GROUP_NAME" | jq -r -r '.data[0].id')" \
  --wait-for-state DELETED

## Remove tag namespace and key
oci iam tag-namespace retire --tag-namespace-id "$TAG_NAMESPACE_ID"
oci iam tag-namespace cascade-delete \
  --tag-namespace-id "$TAG_NAMESPACE_ID" \
  --wait-for-state SUCCEEDED

## Bucket
for RES_ID in $(oci os preauth-request list   --bucket-name "$BUCKET_NAME" | jq -r .data[].id); do
  echo "Deleting Preauth request $RES_ID"
  oci os preauth-request delete --force \
    --bucket-name "$BUCKET_NAME" \
    --par-id "${RES_ID}";
done
oci os object delete --force \
  --bucket-name "$BUCKET_NAME" \
  --object-name "images/${IMAGE_NAME}"
oci os object delete --force \
  --bucket-name "$BUCKET_NAME" \
  --object-name "bootstrap-${CLUSTER_NAME}.ign"
oci os bucket delete --force \
  --bucket-name "$BUCKET_NAME"

# Load Balancer
oci nlb network-load-balancer delete --force \
  --network-load-balancer-id $NLB_ID \
  --wait-for-state SUCCEEDED

# Network and dependencies
for RES_ID in $(oci network subnet list \
  --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  --vcn-id $VCN_ID | jq -r .data[].id); do
  echo "Deleting Subnet $RES_ID"
  oci network subnet delete --force \
    --subnet-id $RES_ID \
    --wait-for-state TERMINATED;
done

for RES_ID in $(oci network nsg list \
  --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  --vcn-id $VCN_ID | jq -r .data[].id); do
  echo "Deleting NSG $RES_ID"
  oci network nsg delete --force \
    --nsg-id $RES_ID \
    --wait-for-state TERMINATED;
done

for RES_ID in $(oci network security-list list \
  --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  --vcn-id $VCN_ID \
  | jq -r '.data[] | select(.["display-name"]  | startswith("Default") | not).id'); do
  echo "Deleting SecList $RES_ID"
  oci network security-list delete --force \
    --security-list-id $RES_ID \
    --wait-for-state TERMINATED;
done

oci network route-table delete --force \
    --wait-for-state TERMINATED \
    --rt-id "$(oci network route-table list \
      --compartment-id "${COMPARTMENT_ID_OPENSHIFT}" \
      --vcn-id "${VCN_ID}" \
      | jq -r '.data[] | select(.[\"display-name\"] | endswith("rtb-public")).id')"

oci network route-table delete --force \
    --wait-for-state TERMINATED \
    --rt-id "$(oci network route-table list \
      --compartment-id "$COMPARTMENT_ID_OPENSHIFT" \
      --vcn-id "$VCN_ID" \
      | jq -r '.data[] | select(.[\"display-name\"] | endswith("rtb-private")).id')"

for RES_ID in $(oci network nat-gateway list \
  --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  --vcn-id $VCN_ID | jq -r .data[].id); do
  echo "Deleting NATGW $RES_ID"
  oci network nat-gateway delete --force \
    --nat-gateway-id $RES_ID \
    --wait-for-state TERMINATED;
done

for RES_ID in $(oci network internet-gateway list \
  --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  --vcn-id $VCN_ID | jq -r .data[].id); do
  echo "Deleting IGW $RES_ID"
  oci network internet-gateway delete --force \
    --ig-id $RES_ID \
    --wait-for-state TERMINATED;
done

oci network vcn delete --force \
  --vcn-id $VCN_ID \
  --wait-for-state TERMINATED

# Compartment
oci iam compartment delete --force \
  --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  --wait-for-state SUCCEEDED