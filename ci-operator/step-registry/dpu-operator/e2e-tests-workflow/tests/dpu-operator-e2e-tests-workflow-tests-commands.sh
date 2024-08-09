#!/bin/bash

wait_for_job_to_run() {
	echo "Waiting for job to start..."
	max_sleep_duration=432000  # Maximum sleep duration in seconds (5 days)
	sleep_counter=0
	while :
	do
		JSON_FILE=$(mktemp /tmp/pullnumber.XXX)
    		curl -k -s --resolve "$endpoint_resolve" "${job_url}/api/json" > $JSON_FILE

    		pullnumber_job=$(cat $JSON_FILE | jq -r '.actions[] | select(.parameters) | .parameters[] | select(.name == "pullnumber") | .value')

    		if [[ "$pullnumber_job" == "$PULL_NUMBER" ]]; then
			ID=$(cat $JSON_FILE | jq -r '.id')	
			break
    		else
        		if [ "$sleep_counter" -ge "$max_sleep_duration" ]; then
            			echo "Exiting- job has not started for longer than 5 days..."
            			exit 1
        		fi
        		sleep_counter=$((sleep_counter + 60))
        		sleep 60
    		fi
	done
}

wait_for_job_to_finish_running() {
	job_url_id="https://${endpoint}/job/$test_name/$ID"
	max_sleep_duration=21600  # Maximum sleep duration in seconds (6 hours)
	sleep_counter=0
	while :
	do	
		JSON_FILE=$(mktemp /tmp/output.XXX)
		curl -k -s --resolve "$endpoint_resolve" "${job_url}/api/json" > $JSON_FILE

    		# Extract the result field
    		result=$(cat $JSON_FILE | jq -r '.result')

    		if [[ "$result" != "null" ]]; then
        		# Job has completed
        		echo "Job Result: $result"
	
			curl_info=$(curl -k -s --resolve "$endpoint_resolve" "${job_url_id}/consoleText")
			echo "$curl_info"
        
			if [ "$result" == "SUCCESS" ]; then
            			exit 0
        		else
            			exit 1
        		fi
    		else
        		if [ "$sleep_counter" -ge "$max_sleep_duration" ]; then
            			echo "Exiting due to long sleep duration..."
            			exit 1
        		fi
        		sleep_counter=$((sleep_counter + 60))
        		sleep 60
    		fi
	done
}

trigger_build() {
	curl -k --resolve "${endpoint_resolve}" "https://${endpoint}/view/dpu-test/job/${test_name}/buildWithParameters?token=$token_dpu_operator_key&pullnumber=$PULL_NUMBER"
}

token_dpu_operator_key=$(cat "/var/run/token/dpu-token/dpu-key")
endpoint=$(cat "/var/run/token/dpu-token/url")
test_name="99_Lab217_E2E_IPU_Deploy"

job_url="https://${endpoint}/job/${test_name}/lastBuild"
endpoint_resolve="${endpoint}:443:10.0.180.88"

trigger_build

wait_for_job_to_run

wait_for_job_to_finish_running

