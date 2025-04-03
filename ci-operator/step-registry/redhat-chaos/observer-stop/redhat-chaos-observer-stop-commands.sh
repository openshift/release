#!/bin/bash

set -o nounset

output=$(oc rsh -n $TEST_NAMESPACE $POD_NAME cat /tmp/test.json)

status_bool=$(echo $output | grep '"cerberus":' | sed 's/.*: //; s/[{},]//g')

replaced_str=$(echo $status_bool | sed "s/True/0/g" | sed "s/False/1/g" )

exit $replaced_str