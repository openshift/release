#!/bin/bash

# Export ES environment variables
# Export ES environment variables
es_host="$(cat /secret/es-host)"
export es_host
es_port="$(cat /secret/es-port)"
export es_port
es_index="${POLICIES_GROUP}-$(cat /secret/cost-es-index)"
export es_index
cost_explorer_tags="$(cat /secret/cost-explorer-tags)"
export cost_explorer_tags


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
