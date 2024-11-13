#!/bin/bash

echoerr() { echo "$@" 1>&2; }

trigger_build() {
    curl --resolve "${endpoint_resolve}" -X POST "$queue_url" -H "Content-Type: application/json" -d "{\"pullnumber\": \"${PULL_NUMBER}\"}"
}

check_pull_number() {
    check_pull_number_response=$(curl --resolve "${endpoint_resolve}" -X POST "${queue_url}/check_pullnumber" -H "Content-Type: application/json" -d "{\"uuid\": \"${1}\"}")
    
    check_pull_number_return_code=$(echo "$check_pull_number_response" | jq -r '.return_code')
    
    while [ -n "$check_pull_number_response" ]; do
        check_pull_number_response=$(curl --resolve "${endpoint_resolve}" -X POST "${queue_url}/check_pullnumber" -H "Content-Type: application/json" -d "{\"uuid\": \"${1}\"}")
        check_pull_number_return_code=$(echo "$check_pull_number_response" | jq -r '.return_code')

        if [[ "$check_pull_number_return_code" == '200' ]] || [[ "$check_pull_number_return_code" == '400' ]]; then
            job_status=$(echo "$check_pull_number_response" | jq -r '.message')

            if [[ "$job_status" == 'SUCCESS' ]]; then
                exit 0
            else    
                exit 1
            fi
        fi
        sleep 300
    done
}

queue_url=$(cat "/var/run/token/dpu-token/queue-url")
queue_endpoint=$(cat "/var/run/token/dpu-token/queue-endpoint")
endpoint_resolve="${queue_endpoint}:80:10.30.44.209"
queue_put_response=$(trigger_build)

if [ $? -ne 0 ]; then
    echoerr "Error: Failed to trigger build."
    exit 1
fi

put_queue_return_code=$(echo "$queue_put_response" | jq -r '.return_code')

if [ "$put_queue_return_code" -eq 200 ]; then
    echo "Success: Successfully added to queue. Return_code is 200"
    uuid=$(echo "$queue_put_response" | jq -r '.message')
    check_pull_number "$uuid"
else
    echo "Error: Queue is full. Returned with: $put_queue_return_code. Try again later."
fi

