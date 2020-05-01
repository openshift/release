#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


echo "************ baremetalds env setup ************"
env | sort

set +x

PACKET_PROJECT_ID=$(cat ${CLUSTER_PROFILE_DIR}/.packet-kni-vars|grep packet_project_id|awk '{print $2}')
PACKET_AUTH_TOKEN=$(cat ${CLUSTER_PROFILE_DIR}/.packet-kni-vars|grep packet_auth_token|awk '{print $2}')
SLACK_AUTH_TOKEN=$(cat ${CLUSTER_PROFILE_DIR}/.slackhook)

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
fi

#Packet API call to get list of servers in project
servers="$(curl -X GET --header 'Accept: application/json' --header "X-Auth-Token: ${PACKET_AUTH_TOKEN}"\
 "https://api.packet.net/projects/${PACKET_PROJECT_ID}/devices?exclude=root_password,ssh_keys,created_by,project,project_lite\
,ip_addresses,plan,meta,operating_system,facility,network_ports&per_page=1000")"

#Assuming all servers created more than 4 hours = 14400 sec ago are leaks
leaks="$(echo "$servers" | jq -r '.devices[]|select((now-(.created_at|fromdate))>14400)')"

leaks_report="$(echo "$leaks" | jq --tab  '.hostname,.id,.created_at,.tags'|sed 's/\"/ /g')"
leak_ids="$(echo "$leaks" | jq -c '.id'|sed 's/\"//g')"
leak_num="$(echo "$leak_ids" | wc -w)"

set -x

echo "************ delete e2e-metal-ipi leaked servers and send slack notification ************"

if [[ -n "$leaks" ]]
then
    echo "$leaks_report"
    set +x
    curl -X POST --data-urlencode\
     "payload={\"text\":\"New Packet.net server leaks total: $leak_num. Deleting the following:\n\",\"attachments\":[{\"color\":\"warning\",\"text\":\"$leaks_report\"}]}"\
      https://hooks.slack.com/services/T027F3GAJ/B011TAG710V/${SLACK_AUTH_TOKEN}
    
    #delete leaks
     for leak in $leak_ids
     do
         echo $leak    
         curl -X DELETE --header 'Accept: application/json' --header "X-Auth-Token: ${PACKET_AUTH_TOKEN}"\
          "https://api.packet.net/devices/$leak"
     done
    set -x
fi
