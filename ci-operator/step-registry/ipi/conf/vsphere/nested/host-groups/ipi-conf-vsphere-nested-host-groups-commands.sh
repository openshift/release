#!/bin/bash

#set -o nounset
#set -o errexit
#set -o pipefail

function log() {
  echo "$(date -u --rfc-3339=seconds) - " + "$1"
}

SHARED_DIR=/home/rvanderp/code/release-devenv/artifacts/shared

log "saving ansible variables required to define the topology of the nested environment"

if [ "${HOSTS}" -ne 2 ]; then
  log "this step requires exactly 2 hosts"
  exit 1
fi

cat > "${SHARED_DIR}"/nested-ansible-host-groups.json" <<EOF
# defines tags to be associated with a region, which is a datacenter.
vc_region_tags:
 - us-east
 - us-west

# defines tags to be associated with a zone, which could be a compute
# cluster or a host.
vc_zone_tags:
 - us-east-1
 - us-east-2 
 - us-west-1
 - us-west-2

# defines the association of tags to objects in the nested vCenter.
# named tags and objects must exist. this merely defines the association.
vc_tag_association:
 -  {
      tag: "us-east",
      object_type: "Datacenter",
      object_name: "nested-cidatacenter-1"
    }

# when defined, each of the tag names will be associated with 
# a host. the list of tags is iterated and assigned to a given
# host. the number of hosts and number of tags should be the same.
vc_host_tags:
 - us-east-1
 - us-east-2

# when defined, a host group will be created for each host group listed
# below. a single host will be placed in each host group. The number of
# hosts and host groups should be same.
vc_host_groups:
 cluster: nested-cicluster-1
 datacenter: nested-cidatacenter-1
 groups:
  - host-group-1
  - host-group-2
EOF