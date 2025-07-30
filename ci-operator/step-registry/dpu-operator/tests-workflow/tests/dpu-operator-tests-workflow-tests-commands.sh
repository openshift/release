#!/bin/bash

token_dpu_operator_key=$(cat "/var/run/token/jenkins-secrets/dpu-key")
endpoint=$(cat "/var/run/token/jenkins-secrets/url")

job_url="https://${endpoint}/job/Lab140_DPU_Operator_Test/lastBuild"

endpoint_resolve="${endpoint}:443:10.0.180.171"

max_sleep_duration=86400  # Maximum sleep duration in seconds (2 hours)
sleep_counter=0
#this is a queue system in case other jobs are running

BUILD_NUMBER=$(curl -k -s --resolve "$endpoint_resolve" "${job_url}/api/json" | jq -r '.actions[]? | select(.["_class"] == "hudson.model.ParametersAction") | .parameters[]? | select(.name == "pullnumber") | .value')

if [ -z "$PULL_NUMBER" ]; then
  echo "Error: PULL_NUMBER is not set"
  exit 1
fi

if [ -z "$BUILD_NUMBER" ]; then
  echo "Error: BUILD_NUMBER is not set"
  exit 1
fi
if [ $PULL_NUMBER == $BUILD_NUMBER ]; then
	curl -k -s --resolve "$endpoint_resolve" "${job_url}/stop"
	sleep 20
fi
while : 
do
    job_check=$(curl -k -s --resolve "$endpoint_resolve" "$job_url/api/json")
    result=$(echo "$job_check" | jq -r '.result')
    if [ $result != "null" ]; then
	sleep $((RANDOM % 61 + 60))
        break
    else
        if [ "$sleep_counter" -ge "$max_sleep_duration" ]; then
            echo "Exiting due to long sleep duration..."
            exit 1
        fi
        sleep_counter=$((sleep_counter + 60))
        sleep 60

    fi
done

curl -k --resolve "${endpoint_resolve}" "https://${endpoint}/job/Lab140_DPU_Operator_Test/buildWithParameters?token=$token_dpu_operator_key&pullnumber=$PULL_NUMBER"

echo "Waiting for job completion..."
max_sleep_duration=7200  # Maximum sleep duration in seconds (2 hours)
sleep_counter=0


while :
do
    job_info=$(curl -k -s --resolve "$endpoint_resolve" "${job_url}/api/json")

    # Extract the result field
    result=$(echo "$job_info" | jq -r '.result')

    if [ "$result" != "null" ]; then
        # Job has completed
        echo "Job Result: $result"
	
	curl_info=$(curl -k -s --resolve "$endpoint_resolve" "${job_url}/consoleText")
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
