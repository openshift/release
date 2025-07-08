#!/bin/bash

# Export ES environment variables
es_host="$(cat /secret/es-host)"
export es_host
es_port="$(cat /secret/es-port)"
export es_port
es_index="${POLICIES_GROUP}-$(cat /secret/policy-es-index)"
export es_index
PERF_SERVICES_URL="$(cat /secret/perf_services_url)"
export PERF_SERVICES_URL
s3_bucket=""
export s3_bucket


account_group="$(cat "/secret/${account_group}")"
export account_group

IFS=","

function run_aggregated_mail(){
  policy="send_aggregated_alerts"
  export policy
  python3 /usr/local/cloud_governance/main.py
}

function run_policy() {
    local policies="$1"
    for policy in $policies; do
        export policy
        regions=("us-east-1" "us-east-2" "us-west-1" "us-west-2" "ap-south-1" "eu-north-1" "eu-west-3" "eu-west-2"
                 "eu-west-1" "ap-northeast-3" "ap-northeast-2" "ap-northeast-1" "ca-central-1" "sa-east-1"
                 "ap-southeast-1" "ap-southeast-2" "eu-central-1")
        for region in "${regions[@]}"; do
            export AWS_DEFAULT_REGION="${region}"
            if [[ -n "$s3_bucket" ]]; then
                policy_output="s3://${s3_bucket}/${LOGS}/${AWS_DEFAULT_REGION}"
                export policy_output
            fi

            echo "Running $policy in region: $AWS_DEFAULT_REGION on account: $account_name"

            if [[ "$policy" == "empty_roles" || "$policy" == "s3_inactive" ]] && [[ "$region" == "us-east-1" ]]; then
                python3 /usr/local/cloud_governance/main.py
            else
                if [[ "$policy" != "empty_roles" && "$policy" != "s3_inactive" ]]; then
                    python3 /usr/local/cloud_governance/main.py
                fi
            fi
        done
    done
}

function run_policies() {
    local policies="$1"
    for account_name in ${account_group}; do
        export account_name
        # Load credentials
        secret_file="/secret/${account_name}"
        if [[ ! -f "$secret_file" ]]; then
            echo "Error: Secret file for ${account_name} not found!"
            exit 1
        fi

        cat "$secret_file" > /tmp/creds.sh
        chmod 600 /tmp/creds.sh
        source /tmp/creds.sh

        echo "Running policies for ${account_name}"
        run_policy "$policies"
        echo "Running Email alert"
        run_aggregated_mail
        echo "Exiting ${account_name}"
        echo
    done
}

for dry_run in "yes" "no"; do
    export dry_run
    echo "Running policies on dry_run=${dry_run}"
    var_name="${POLICIES_GROUP}-policies-dry-run-${dry_run}"
    policies="$(cat "/secret/${var_name}")"
    run_policies "${policies}"

done

# Run AWS Cost-Explorer policies
echo
echo

es_index="${POLICIES_GROUP}-$(cat /secret/cost-es-index)"
export es_index
cost_explorer_tags_arr=(
  "PurchaseType" "ChargeType" "User" "Budget" "Project" "Manager"
  "Owner" "LaunchTime" "Email" "Environment" "User:Spot" "cluster_id"
)

cost_explorer_tags="$(printf '"%s",' "${cost_explorer_tags_arr[@]}" | sed 's/,$//')"
cost_explorer_tags="[$cost_explorer_tags]"
cost_metric="UnblendedCost"  # UnblendedCost/BlendedCost
granularity="DAILY"  # DAILY/MONTHLY/HOURLY
policy="cost_explorer"
export policy
export cost_metric
export granularity
export cost_explorer_tags


function run_cost_policy(){
    for account_name in ${account_group};do

        # Load credentials
        cat "/secret/${account_name}" > /tmp/creds.sh
        chmod 600 /tmp/creds.sh
        source /tmp/creds.sh

        # Run policy function
        echo "Running the CloudGovernance CostExplorer Policies on:- ${account_name}"
        python3 /usr/local/cloud_governance/main.py
        echo "exiting ${account_name}"
        echo 

    done
}

run_cost_policy

echo "All policies executed successfully."
echo
