#!/bin/bash

set -o nounset
set +o pipefail

output_code=1

CREATED_POD_NAME=$(oc get pods -n $TEST_NAMESPACE --no-headers | awk '{print $1}')
echo "created pod name $CREATED_POD_NAME"
counter=0
while [[ $output_code == 1 ]]; do
    output=$(oc rsh -n $TEST_NAMESPACE $CREATED_POD_NAME cat /tmp/test.json)
    output_code=$?
    sleep 5
    echo "output $output"
    echo "output_code $output_code"
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
