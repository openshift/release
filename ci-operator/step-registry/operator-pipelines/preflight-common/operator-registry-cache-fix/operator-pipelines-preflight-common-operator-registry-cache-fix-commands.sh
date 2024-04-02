#!/usr/bin/env bash

echo "Check if catalog sources are healthy"

echo "Writing pods and statuses to disk"
oc get pods -n openshift-marketplace -o "jsonpath={range .items[*]}{.metadata.name}{' '}{.status.phase}{'\n'}{end}" > catalog-sources-status

echo "Read pods and statuses from disk; if any pod has status CrashLoopBackoff delete pod"
while IFS=' ' read -r podName status
do
  if [ "$status" == "CrashLoopBackoff" ]; then
    echo "Deleting $podName"
    oc delete -n openshift-marketplace pod/"$podName"
  fi
done < catalog-sources-status

echo "Wait one minute for any deleted pods to return"
sleep 60

echo "Completed check and resolve of catalog sources"
exit 0