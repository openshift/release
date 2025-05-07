#!/bin/bash

set -o nounset


output_code=1

counter=0
while [[ $output_code == 1 ]]; do
    output=$(oc rsh -n $TEST_NAMESPACE $POD_NAME cat /tmp/test.json)
    output_code=$?
    sleep 5
    counter=$((counter+1))

    if [[ $counter -gt 15 ]]; then
        exit 1
    fi
done

oc cluster-info

status_bool=$(echo $output | grep '"cerberus":' | sed 's/.*: //; s/[{},]//g')

echo "$status_bool staus bool "

replaced_str=$(echo $status_bool | sed "s/True/0/g" | sed "s/False/1/g" )
echo "$replaced_str replaced str"
exit $((replaced_str))