#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set +x

PACKET_PROJECT_ID=$(cat "${CLUSTER_PROFILE_DIR}/packet-project-id")
PACKET_AUTH_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/packet-auth-token")
SLACK_AUTH_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/slackhook")

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
fi

#Packet API call to get list of servers in project
servers="$(curl -X GET --header 'Accept: application/json' --header "X-Auth-Token: ${PACKET_AUTH_TOKEN}" \
 "https://api.packet.net/projects/${PACKET_PROJECT_ID}/devices?exclude=root_password,ssh_keys,created_by,project,project_lite,ip_addresses,plan,meta,operating_system,facility,network_ports&per_page=1000"
)"

#Assuming all servers created more than 4 hours = 14400 sec ago are leaks
leaks="$(echo "$servers" | jq -r '.devices[]|select((now-(.created_at|fromdate))>14400 and any(.hostname; startswith("ipi-")))')"

leak_report="$(echo "$leaks" | jq --tab  '.hostname,.id,.created_at,.tags'|sed 's/\"/ /g')"
leak_ids="$(echo "$leaks" | jq -c '.id'|sed 's/\"//g')"
leak_servers="$(echo "$leaks" | jq -c '.hostname'|sed 's/\"//g')"
leak_num="$(echo "$leak_ids" | wc -w)"

leak_report="${leak_report}\nProw job references per leaked server:" 
for server in $leak_servers
do
  leak_report="${leak_report}\n<https://search.ci.openshift.org/?search=$server&maxAge=48h&context=-1&type=build-log|$server>"
done
set -x

echo "New Packet.net server leaks total: $leak_num."
set +x
if [[ -n "$leaks" ]]
then
    #send slack notification and delete e2e-metal-ipi leaked servers 
    curl -X POST --data-urlencode\
     "payload={\"text\":\"New Packet.net server leaks total: $leak_num. Deleting the following:\n\",\"attachments\":[{\"color\":\"warning\",\"text\":\"$leak_report\"}]}"\
     "https://hooks.slack.com/services/T027F3GAJ/B011TAG710V/${SLACK_AUTH_TOKEN}"

    #delete leaks
    for leak in $leak_ids
    do
        #echo $leak    
        curl -X DELETE --header 'Accept: application/json' --header "X-Auth-Token: ${PACKET_AUTH_TOKEN}"\
         "https://api.packet.net/devices/$leak"
    done
fi
set -x
