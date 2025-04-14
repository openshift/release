#!/bin/bash

# Export ES environment variables
# Export ES environment variables
es_host="$(cat /secret/es-host)"
export es_host
es_port="$(cat /secret/es-port)"
export es_port
es_index="${POLICIES_GROUP}-$(cat /secret/cost-es-index)"
export es_index
cost_explorer_tags_arr=(
  "PurchaseType" "ChargeType" "User" "Budget" "Project" "Manager"
  "Owner" "LaunchTime" "Email" "Environment" "User:Spot" "cluster_id"
)

# Convert array to JSON-like string (double-quoted, comma-separated)
cost_explorer_tags="$(printf '"%s",' "${cost_explorer_tags_arr[@]}" | sed 's/,$//')"
cost_explorer_tags="[$cost_explorer_tags]"
export cost_explorer_tags

account_group="$(cat "/secret/${account_group}")"
export account_group

IFS=","


function run_policy(){

    python3 /usr/local/cloud_governance/main.py
}

function run_accounts(){
  for account_name in ${account_group};do

    # Load credentials
    cat "/secret/${account_name}" > /tmp/creds.sh
    chmod 600 /tmp/creds.sh
    source /tmp/creds.sh

    echo "Running the CloudGovernance CostExplorer Policies on:- ${account_name}"
    # Run policy function
    run_policy
    echo "exiting ${account_name}"
    echo 

  done
  
}

run_accounts
