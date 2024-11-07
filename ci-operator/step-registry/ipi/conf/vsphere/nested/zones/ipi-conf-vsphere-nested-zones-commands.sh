#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

declare NESTED_DATACENTERS
declare NESTED_CLUSTERS

function log() {
  echo "$(date -u --rfc-3339=seconds) - " + "$1"
}

declare NESTED_CLUSTER
log "saving ansible variables required to define the topology of the nested environment"

cat > "${SHARED_DIR}/nested-ansible-group-vars.yaml" <<EOF
# defines tags to be associated with a region, which is a datacenter.
vc_region_tags:
$(
for i in $(seq 0 $((NESTED_DATACENTERS - 1))); do 
echo "- cidatacenter-nested-${i}"
done
)

# defines tags to be associated with a zone, which could be a compute
# cluster or a host.
vc_zone_tags:
$(
for i in $(seq 0 $((NESTED_DATACENTERS - 1))); do 
  NESTED_DATACENTER="cidatacenter-nested-${i}"
  for c in $(seq 0 $((NESTED_CLUSTERS - 1))); do    
    echo "- ${NESTED_DATACENTER}-cicluster-nested-${c}"
  done
done
)

# defines the association of tags to objects in the nested vCenter.
# named tags and objects must exist. this merely defines the association.
vc_tag_association:
$(
for i in $(seq 0 $((NESTED_DATACENTERS - 1))); do 
echo "- {
    tag: \"cidatacenter-nested-${i}\",
    object_type: \"Datacenter\",
    object_name: \"cidatacenter-nested-${i}\"
}"
done
)

$(
for i in $(seq 0 $((NESTED_DATACENTERS - 1))); do 
  NESTED_DATACENTER="cidatacenter-nested-${i}"
  for c in $(seq 0 $((NESTED_CLUSTERS - 1))); do    
    echo "-  {
    tag: \"${NESTED_DATACENTER}-cicluster-nested-${c}\",
    object_type: \"ClusterComputeResource\",
    object_name: \"cicluster-nested-${c}\"
}"
  done
done
)

EOF

cat > "${SHARED_DIR}/nested-ansible-platform.yaml" <<EOF
platform:
  vsphere:
    vcenters:
      - server: \${NESTED_VCENTER}
        user: "administrator@vsphere.local"
        password: "\${vcenter_password}"
        datacenters:
$(
for i in $(seq 0 $((NESTED_DATACENTERS - 1))); do 
echo "        - cidatacenter-nested-${i}"
done
)
    failureDomains:
$(
for i in $(seq 0 $((NESTED_DATACENTERS - 1))); do 
  NESTED_DATACENTER="cidatacenter-nested-${i}"
  
  for c in $(seq 0 $((NESTED_CLUSTERS - 1))); do
    NESTED_CLUSTER="cicluster-nested-${c}"
    echo "
      - server: \${NESTED_VCENTER}
        name: \"${NESTED_DATACENTER}-${NESTED_CLUSTER}\"
        zone: \"${NESTED_DATACENTER}-${NESTED_CLUSTER}\"
        region: ${NESTED_DATACENTER}
        topology:
          resourcePool: /${NESTED_DATACENTER}/host/${NESTED_CLUSTER}/Resources/ipi-ci-clusters
          computeCluster: /${NESTED_DATACENTER}/host/${NESTED_CLUSTER}
          datacenter: ${NESTED_DATACENTER}
          datastore: /${NESTED_DATACENTER}/datastore/dsnested
          networks:
            - \${GOVC_NETWORK}"
  done
done
)
    apiVIP: "\${API_VIP}"
    ingressVIP: "\${INGRESS_VIP}"
EOF