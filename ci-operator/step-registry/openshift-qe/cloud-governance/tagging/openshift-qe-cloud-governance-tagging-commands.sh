#!/bin/bash

# Export ES environment variables
es_host="$(cat /secret/es_host)"
export es_host
es_port="$(cat /secret/es_port)"
export es_port
perf_services_url="$(cat /secret/perf_services_url)"
export perf_services_url
account_group="$(cat /secret/${account_group})"
s3_bucket=""
export s3_bucket
IFS=","

function run_policy(){
    regions=("us-east-1" "us-east-2" "us-west-1" "us-west-2" "ap-south-1" "eu-north-1" "eu-west-3" "eu-west-2"
             "eu-west-1" "ap-northeast-3" "ap-northeast-2" "ap-northeast-1" "ca-central-1" "sa-east-1"
             "ap-southeast-1" "ap-southeast-2" "eu-central-1")
    for region in "${regions[@]}"; do
        AWS_DEFAULT_REGION="${region}"
        export AWS_DEFAULT_REGION
        if [[ -n "$s3_bucket" ]]; then
          policy_output="s3://${s3_bucket}/${LOGS}/${AWS_DEFAULT_REGION}"
          export policy_output
        fi
        python3 /usr/local/cloud_governance/main.py
    done
}

function run_accounts(){
  for account_name in ${account_group};do

    # Load credentials
    cat "/secret/${account_name}" > /tmp/creds.sh
    chmod 600 /tmp/creds.sh
    source /tmp/creds.sh

    mandatory_tags=$(printf '{"Budget": "%s"}' "$account_name")
    export mandatory_tags

    echo "Running ${account_name}"
    # Run policy function
    run_policy
    echo "exiting ${account_name}\n\n"

  done
  
}

run_accounts
