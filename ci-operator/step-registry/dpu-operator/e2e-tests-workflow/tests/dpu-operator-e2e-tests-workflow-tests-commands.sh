#!/bin/bash

echoerr() { echo "$@" 1>&2; }

check_timeout_status() {
        curl --resolve "${endpoint_resolve}" -X POST "$queue_url/check_timed_out_job" -H "Content-Type: application/json" -d "{\"pull_pull_sha\": \"${PULL_PULL_SHA}\"}"
}

trigger_build() {
	curl --resolve "${endpoint_resolve}" -X POST "$queue_url" -H "Content-Type: application/json" -d "{\"pullnumber\": \"${PULL_NUMBER}\", \"pull_pull_sha\": \"${PULL_PULL_SHA}\"}"

}


handle_job_status() {
    local response="$1"
    
    return_code=$(echo "$response" | jq -r '.return_code')

    if [[ "$return_code" == '200' ]] || [[ "$return_code" == '400' ]]; then
        job_status=$(echo "$response" | jq -r '.message')
        job_console=$(echo "$response" | jq -r '.console_logs')

        echo "$job_console"

        if [[ "$job_status" == 'SUCCESS' ]]; then
            exit 0
        else
            exit 1
        fi
    fi
}

# Main function to check the pull number and handle retries
check_pull_number() {
    check_pull_number_response=$(curl --resolve "${endpoint_resolve}" -X POST "${queue_url}/check_pullnumber" -H "Content-Type: application/json" -d "{\"uuid\": \"${1}\"}")

    handle_job_status "$check_pull_number_response"

    while true; do
        check_pull_number_response=$(curl --resolve "${endpoint_resolve}" -X POST "${queue_url}/check_pullnumber" -H "Content-Type: application/json" -d "{\"uuid\": \"${1}\"}")
        
        handle_job_status "$check_pull_number_response"

        sleep 100
    done
}

queue_url=$(cat "/var/run/token/e2e-test/queue-url")
queue_endpoint=$(cat "/var/run/token/e2e-test/queue-endpoint")
ip_address=$(cat "/var/run/token/e2e-test/ip-address")
endpoint_resolve="${queue_endpoint}:80:${ip_address}"

#Check timeout wa
timed_out_response=$(check_timeout_status)

check_timed_out_return_code=$(echo "$timed_out_response" | jq -r '.return_code')

if [ "$check_timed_out_return_code" -eq 400 ]; then
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
else
	echo "Previous run has timed out. This pull requests sha is being tested or has already finished testing"
	uuid=$(echo "$timed_out_response" | jq -r '.message')
	check_pull_number "$uuid"
fi
