#!/usr/bin/env bash

# This step checks the /readyz endpoint to confirm the
# Kubernetes environment is ready for interaction. This
# step is most useful when claiming clusters that have
# been hibernating for an extended period of time.

echo "Health endpoint and cluster operators check"

export KUBECONFIG

OPERATOR_HEALTH_TIMEOUT=${OPERATOR_HEALTH_TIMEOUT:-15}

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Checking readyz endpoint"

function checkreadyz() {
    for (( n=1; n<=10; n++ ))
    do
        api=$(oc get --raw='/readyz')
        if test "${api}" != "ok"
        then
            echo "Health check endpoint readyz not ok; checking again in one minute"
            sleep 60
            continue
	else
            echo "Health check endpoint readyz ok"
            isreadyz="ok"
	    return
        fi
    done

    isreadyz="nok"
}

checkreadyz

if test "${isreadyz}" != "ok"
then
    echo "Health check endpoint readyz failed after 10 minutes; exiting"
    exit 1
fi

echo "Checking cluster operators"

function checkoperators() {
    for op in $(oc get clusteroperators | awk 'NR>1 { print $3 $4 $5 }')
    do
        if test "${op}" == "TrueFalseFalse"
        then
	    continue
	else
            iscop="nok"
            return
        fi
    done

    iscop="ok"
}

for (( n=1; n<=OPERATOR_HEALTH_TIMEOUT; n++ ))
do
    checkoperators

    if test "${iscop}" == "ok"
    then
        echo "Cluster operators ready"
	exit 0
    fi

    echo "Cluster operators not ready; checking again in one minute"
    sleep 60
done

echo "Cluster operators not ready after 10 minutes; exiting"
exit 1
