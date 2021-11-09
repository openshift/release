#!/usr/bin/env bash

# This step checks the /readyz endpoint to confirm the
# Kubernetes environment is ready for interaction. This
# step is most useful when claiming clusters that have
# been hibernating for an extended period of time.

echo "Wait up to 10m for readyz to return ok"

export KUBECONFIG

for (( n=1; n<=10; n++ ))
do
    health=$(oc get --raw='/readyz')
    if test "${health}" == "ok"
    then
	echo "Health check succeeded"
	exit 0
    fi
    sleep 60
done

echo "Health check failed."
exit 1
