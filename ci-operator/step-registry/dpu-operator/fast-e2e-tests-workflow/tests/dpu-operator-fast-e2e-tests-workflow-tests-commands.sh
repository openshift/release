#!/bin/bash

echoerr() { echo "$@" 1>&2; }

trigger_build() {
	curl -sik --resolve "$endpoint_resolve" "https://${endpoint}/job/${test_name}/buildWithParameters?token=${dpu_token}&pullnumber=${PULL_NUMBER}" | grep location: | tr -d '\r\n' | cut -d' ' -f2
}

wait_for_job_to_run() {
	echoerr "Waiting for job to start..."
	# Maximum sleep duration in seconds (5 days)
	max_sleep_duration=432000
	sleep_counter=0

	while :
	do
		JSON_FILE=$(mktemp /tmp/pullnumber.XXX)
		curl -k --resolve "$endpoint_resolve" -X GET $1/api/json > $JSON_FILE
		blocked=$(cat $JSON_FILE | jq .why)

                if [[ "$blocked" != "null" && "$blocked" =~ ^\"(.*)\"$ ]]; then
    			blocked="${BASH_REMATCH[1]}"
                fi

		if [[ "$blocked" == "Waiting for next available executor on "* ]]; then
			echo "Job is blocked, waiting for job to start"
		elif [[ "$blocked" == "null" ]]; then
			cat $JSON_FILE | jq -r .executable.url
			break
		else
			echo "Error: unknown value of blocked variable: $blocked"
			exit 1
		fi

		if [ "$sleep_counter" -ge "$max_sleep_duration" ]; then
			echo "Exiting- job has not started for longer than 5 days..."
			exit 1
		fi
		sleep_counter=$((sleep_counter + 60))
		sleep 60
	done
}

wait_for_job_to_finish_running() {
	echoerr "Waiting for job to finish..."
	local job_url=$1/api/json
	local max_sleep_duration=21600  # Maximum sleep duration in seconds (6 hours)
	local sleep_counter=0

	while :
	do
		JSON_FILE=$(mktemp /tmp/output.XXX)
		curl -k -s --resolve "$endpoint_resolve" "$job_url" > "$JSON_FILE"

		# Extract the result field
		result=$(jq -r '.result' < "$JSON_FILE")

		if [[ "$result" != "null" ]]; then
			# Job has completed
			echo "Job Result: $result"
			curl_info=$(curl -k -s --resolve "$endpoint_resolve" "$1/consoleText")
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

endpoint=$(cat "/var/run/token/dpu-token/url")
dpu_token=$(cat "/var/run/token/dpu-token/dpu-key")
test_name="99_FAST_E2E_IPU_Deploy"
endpoint_resolve="${endpoint}:443:10.0.180.88"
job_url="https://${endpoint}/job/${test_name}/lastBuild"

job_queue_item=$(trigger_build)
job_url=$(wait_for_job_to_run "$job_queue_item" | tail -n1)
wait_for_job_to_finish_running "$job_url"
