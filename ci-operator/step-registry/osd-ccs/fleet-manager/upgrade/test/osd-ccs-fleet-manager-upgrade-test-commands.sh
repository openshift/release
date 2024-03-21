#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Log in with OSDFM token
OCM_VERSION=$(ocm version)
OSDFM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/fleetmanager-token")
if [[ ! -z "${OSDFM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OSDFM_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token OSDFM_TOKEN!"
  exit 1
fi

# REMOVE
# HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION="4.14.17"

# MC details
mc_ocm_cluster_id="2a4qben6sk0u168g7dae3kpvmtmvfgln"
# REMOVE
ocm get /api/clusters_mgmt/v1/clusters/"$mc_ocm_cluster_id"/credentials | jq -r .kubeconfig > "${SHARED_DIR}/hs-mc.kubeconfig"
MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"

for ((i=0; i<360; i+=1)); do
  oc --kubeconfig "$MC_KUBECONFIG" get mcp/master || true
  oc --kubeconfig "$MC_KUBECONFIG" get mcp/worker || true
  oc --kubeconfig "$MC_KUBECONFIG" get co -A || true
  oc --kubeconfig "$MC_KUBECONFIG" get nodes -A || true
  oc --kubeconfig "$MC_KUBECONFIG" get clusterversion || true
  sleep 10
done

# HC details
# HC_KUBECONFIG="${SHARED_DIR}/hc-kubeconfig"
# HC_VERSION=""

# function get_hc_details () {
#   HC_KUBEADMIN_SECRET_NAME=$(oc --kubeconfig "$MC_KUBECONFIG" get hc -A | tail -1 | awk '{print $4}')
#   HC_NS_NAME=$(oc --kubeconfig "$MC_KUBECONFIG" get hc -A | tail -1 | awk '{print $1}')
#   ## save HC kubeconfig
#   oc --kubeconfig "$MC_KUBECONFIG" get secret "$HC_KUBEADMIN_SECRET_NAME" -n "$HC_NS_NAME" -o json | jq -r '.data.kubeconfig | @base64d' > "$HC_KUBECONFIG"
#   HC_VERSION=$(oc --kubeconfig "$HC_KUBECONFIG" get co -A | head -2 | tail -1 | awk '{print $2}') || true
#   echo "HC cluster operators version is: $HC_VERSION"
# }

# get_hc_details

# function get_highest_z_version_upgrade () {
#   AVAILABLE_UPGRADE_VERSIONS=$1
#   CURRENT_V=$2
#   VERSIONS_SIZE=$3
#   IFS='.' read -r -a CURRENT_SEPARATED <<< "$CURRENT_V"
#   CURRENT_HIGHEST_PATCH=${CURRENT_SEPARATED[2]}
#   CURRENT_HIGHEST_MINOR=${CURRENT_SEPARATED[1]}
#   CURRENT_HIGHEST_MAJOR=${CURRENT_SEPARATED[0]}
#   for ((i=0; i<"$VERSIONS_SIZE"; i++)); do
#     VERSION=$(jq -n "$AVAILABLE_UPGRADE_VERSIONS" | jq -r .[$i])
#     echo "version to check: $VERSION"
#     IFS='.' read -r -a CURRENT_SEPARATED_UPGRADE_VERSION <<< "${VERSION}"
#     if [ "${CURRENT_SEPARATED_UPGRADE_VERSION[0]}" -eq "$CURRENT_HIGHEST_MAJOR" ] && [ "${CURRENT_SEPARATED_UPGRADE_VERSION[1]}" -eq "$CURRENT_HIGHEST_MINOR" ] && [ "${CURRENT_SEPARATED_UPGRADE_VERSION[2]}" -gt "$CURRENT_HIGHEST_PATCH" ]; then
#       CURRENT_HIGHEST_PATCH=${CURRENT_SEPARATED_UPGRADE_VERSION[2]}
#       CURRENT_HIGHEST_MINOR=${CURRENT_SEPARATED_UPGRADE_VERSION[1]}
#       CURRENT_HIGHEST_MAJOR=${CURRENT_SEPARATED_UPGRADE_VERSION[0]}
#       HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION="$VERSION"
#     fi
#   done
# }

# echo "Checking current openshift version of MC with ocm API cluster ID: $mc_ocm_cluster_id"
# CURRENT_VERSION=$(ocm get /api/clusters_mgmt/v1/clusters/"$mc_ocm_cluster_id" | jq -r .version.raw_id)
# echo "Current openshift version of MC with ocm API cluster ID: $mc_ocm_cluster_id is: $CURRENT_VERSION"
# echo "Checking available upgrades of MC with ocm API cluster ID: $mc_ocm_cluster_id"
# AVAILABLE_UPGRADES=$(ocm get /api/clusters_mgmt/v1/clusters/"$mc_ocm_cluster_id" | jq -r .version.available_upgrades)
# NO_OF_VERSIONS=$(jq -n "$AVAILABLE_UPGRADES" | jq '. | length')
# HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION=""

# get_highest_z_version_upgrade "${AVAILABLE_UPGRADES[@]}" "$CURRENT_VERSION" "$NO_OF_VERSIONS"
# echo "Highest available patch upgrade is: $HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION"
# if [ "$HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION" == "" ]; then
#   echo "No available upgrades found"
# else
#   echo "Available version upgrades are: $AVAILABLE_UPGRADES"
#   echo "Upgrading openshift version of MC with ocm API cluster ID: $mc_ocm_cluster_id to version: $HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION"
#   oc --kubeconfig "$MC_KUBECONFIG" adm upgrade --to="$HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION"
#   echo "Sleep for 5 minutes to give time for the upgrade to start"
#   sleep 300
# fi

## upgrade progress checks

# # MC_CO_UPGRADED=false
# MC_MCP_UPDATED=false
# MC_NODES_UPDATED=false
# MC_UPGRADE_COMPLETE=false

# ### check HC status
# FAILED_HC_INFO_CHECK_COUNTER=0
# function check_cluster_operators_info () {
#   echo "Checking HC operators info available"
  
#   CLUSTER_OPERATORS_INFO=""
#   CLUSTER_OPERATORS_INFO=$(oc --request-timeout=5s --kubeconfig "$HC_KUBECONFIG" get co -A --insecure-skip-tls-verify | tail -n +2) || true
#   if [ "$CLUSTER_OPERATORS_INFO" == "" ]; then
#     ((FAILED_HC_INFO_CHECK_COUNTER++))
#   fi
# }

### check MC status in four subsequent functions
# function check_cluster_operators_upgraded () {
#   printf "Checking cluster operators upgraded to: %s" "$HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION"
#   UPGRADING_CO_COUNT=-1 # there might be an issue with executing oc commands during upgrade, so for safety this is set to -1
#   CLUSTER_OPERATORS_COUNT=0
#   echo "CLUSTER_OPERATORS_COUNT: $CLUSTER_OPERATORS_COUNT"
#   CLUSTER_OPERATORS_INFO=""
#   CLUSTER_OPERATORS_INFO=$(oc --kubeconfig "$MC_KUBECONFIG" get co -A | tail -n +2) || true # failed execution just results in operators count being 0
#   echo "CLUSTER_OPERATORS_INFO: $CLUSTER_OPERATORS_INFO"
#   if [ "$CLUSTER_OPERATORS_INFO" != "" ]; then
#     CLUSTER_OPERATORS_COUNT=$(echo "$CLUSTER_OPERATORS_INFO" | wc -l) || true # failed execution just results in operators count being 0
#   fi

#   echo "CLUSTER_OPERATORS_COUNT: $CLUSTER_OPERATORS_COUNT"

#   for ((i=1; i<="$CLUSTER_OPERATORS_COUNT"; i++)); do
#     UPGRADING_CO_COUNT=0
#     CO_INFO=$(echo "$CLUSTER_OPERATORS_INFO" | head -n $i | tail -n +$i) || true
#     UPGRADE_PROGRESSING=$(echo "$CO_INFO" | awk '{print $4}') || true
#     CURRENT_VERSION=$(echo "$CO_INFO" | awk '{print $2}') || true
#     if [ "${CURRENT_VERSION}" != "$HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION" ] || [ "$UPGRADE_PROGRESSING" == "True" ]; then
#       ((UPGRADING_CO_COUNT++))
#       break
#     fi
#   done
#   if [ "$UPGRADING_CO_COUNT" -eq 0 ]; then
#     MC_CO_UPGRADED=true
#     printf " ✅\n"
#   else
#     MC_CO_UPGRADED=false
#     printf " ❌\n"
#   fi
# }

# function check_mcp_status () {
#   echo "Checking mps are updated, not updating and not degraded"
#   function check_mcp() {
#     MCP_NAME=$1
#     MCP_STATUS=$(oc --kubeconfig "$MC_KUBECONFIG" get "$MCP_NAME" | tail -n +2) || true
#     MCP_UPDATED=$(echo "$MCP_STATUS" | awk '{print $3}') || true
#     MCP_UPDATING=$(echo "$MCP_STATUS" | awk '{print $4}') || true
#     MCP_DEGRADED=$(echo "$MCP_STATUS" | awk '{print $5}') || true
#     if [ "${MCP_UPDATED}" != "True" ] || [ "$MCP_UPDATING" == "True" ] || [ "$MCP_DEGRADED" == "True" ]; then
#       echo "MCP: '$MCP_NAME' updated: '$MCP_UPDATED', updating: '$MCP_UPDATING', degraded: '$MCP_DEGRADED'"
#     else
#       if [ "$MCP_NAME" == "mcp/master" ]; then
#         MCP_MASTER_UPDATED=true
#       else
#         MCP_WORKER_UPDATED=true
#       fi
#     fi
#   }

#   MCP_WORKER_UPDATED=false
#   MCP_MASTER_UPDATED=false
#   check_mcp "mcp/master"
#   check_mcp "mcp/worker"
#   if [ "$MCP_WORKER_UPDATED" = true ] && [ "$MCP_MASTER_UPDATED" = true ]; then
#     echo "mcps updated"
#     MC_MCP_UPDATED=true
#   else
#     MC_MCP_UPDATED=false
#   fi
# }

# function check_nodes () {
#   echo "Checking nodes are ready"
#   NOT_READY_NODES_COUNT=-1 # there might be an issue with executing oc commands during upgrade, so for safety this is set to -1
#   NODES_COUNT=0
#   NODES_INFO=$(oc --kubeconfig "$MC_KUBECONFIG" get nodes | tail -n +2) || true # failed execution just results in node count being 0
#   NODES_COUNT=$(echo "$NODES_INFO" | wc -l) || true # failed execution just results in node count being 0
#   if [ "$NODES_COUNT" != "" ]; then
#     for ((i=1; i<="$NODES_COUNT"; i++)); do
#       NOT_READY_NODES_COUNT=0
#       NODE_INFO=$(echo "$NODES_INFO" | head -n $i | tail -n +$i) || true
#       NODE_ADDRESS=$(echo "$NODE_INFO" | awk '{print $1}') || true
#       NODE_STATUS=""
#       NODE_STATUS=$(echo "$NODE_INFO" | awk '{print $2}') || true
#       NODE_TYPE=$(echo "$NODE_INFO" | awk '{print $3}') || true
#       if [ "${NODE_STATUS}" != "Ready" ]; then
#         ((NOT_READY_NODES_COUNT++))
#         echo "Node(s) are still upgrading. '$NODE_ADDRESS' ($NODE_TYPE) status is: '$NODE_STATUS'"
#         break
#       fi
#     done
#   fi
#   if [ "$NOT_READY_NODES_COUNT" -eq 0 ]; then
#     echo "Nodes updated"
#     MC_NODES_UPDATED=true
#   else
#     MC_NODES_UPDATED=false
#   fi 
# }

# function check_upgrade_complete () {
#   echo "Checking openshift version on MC is upgraded to '$HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION'"
#   CLUSTER_VERSION_INFO=""
#   CLUSTER_VERSION_INFO=$(oc --kubeconfig "$MC_KUBECONFIG" get clusterversion | tail -1) || true
#   if [ "$CLUSTER_VERSION_INFO" == "" ]; then
#     echo "Unable to get clusterversion. Skipping this time"
#   else
#     CURRENT_VERSION=$(echo "$CLUSTER_VERSION_INFO" | awk '{print $2}') || true
#     UPGRADE_PROGRESSING=$(echo "$CLUSTER_VERSION_INFO" | awk '{print $4}') || true
#     if [ "${CURRENT_VERSION}" == "$HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION" ] && [ "$UPGRADE_PROGRESSING" != "True" ]; then
#       echo "Clusterversion at correct version" 
#       MC_UPGRADE_COMPLETE=true
#     else
#       MC_UPGRADE_COMPLETE=false
#     fi 
#   fi
# }

# while [ "$MC_MCP_UPDATED" = false ] || [ "$MC_NODES_UPDATED" = false ] || [ "$MC_UPGRADE_COMPLETE" = false ]; do
#   TIMESTAMP=$(date +"%Y-%m-%d %T")
#   echo "------ $TIMESTAMP ------"
#   check_cluster_operators_info

#   # check_cluster_operators_upgraded

#   check_mcp_status

#   check_nodes

#   check_upgrade_complete

#   ## break the loop if highest available version is empty
#   if [ "$HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION" == "" ]; then
#     MC_UPGRADE_COMPLETE=true
#     # MC_CO_UPGRADED=true
#   fi

#   echo "Sleep for 10 seconds"
#   sleep 10
# done

# echo "Upgrade complete! Failed HC checks: $FAILED_HC_INFO_CHECK_COUNTER"
