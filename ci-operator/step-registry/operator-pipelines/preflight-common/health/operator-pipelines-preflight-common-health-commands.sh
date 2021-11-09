#!/usr/bin/env bash

# This step checks the /readyz endpoint to confirm the
# Kubernetes environment is ready for interaction. This
# step is most useful when claiming clusters that have
# been hibernating for an extended period of time.

echo "Health endpoint and cluster operators check"

export KUBECONFIG



echo "Checking readyz endpoint"

for (( n=1; n<=10; n++ ))
do
    api=$(oc get --raw='/readyz')
    if test "${api}" == "ok"
    then
	echo "Health check endpoint readyz ok"
	break
    fi
    echo "Health check endpoint readyz not ok; checking again in one minute"
    sleep 60
done



echo "Checking cluster operators"

for (( n=1; n<=10; n++ ))
do
    cops="false"
    for op in $(oc get clusteroperators | awk 'NR>1 { print $3 $4 $5 }')
    do
        if test "${op}" != "TrueFalseFalse"
        then
	    break
	else
            cops="true"
        fi
    done

    if test "${cops}" == "false"
    then
        echo "Some cluster operators not ready; checking again in one minute"
	sleep 60
    else
        echo "Cluster operators ready"
	exit 0
    fi
done

echo "Health checks failed"
exit 1
