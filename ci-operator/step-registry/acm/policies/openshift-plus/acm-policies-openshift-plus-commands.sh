#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# cd to writeable directory
cd /tmp/

git clone -b fix-quay-clair-hpa-overscaling https://github.com/tanfengshuang/policy-collection.git

sleep 60

cd policy-collection/deploy/
echo 'y' | ./deploy.sh -p policygenerator/policy-sets/stable/openshift-plus -n policies -u https://github.com/tanfengshuang/policy-collection.git -b fix-quay-clair-hpa-overscaling -a openshift-plus

sleep 120

# wait for policies to be compliant
RETRIES=40
for try in $(seq "${RETRIES}"); do
  results=$(oc get policies -n policies)
  notready=$(echo "$results" | grep -E 'NonCompliant|Pending' || true)
  if [ "$notready" == "" ]; then
    echo "OPP policyset is applied and compliant"
    break
  else
    if [ $try == $RETRIES ]; then
      if [ "$IGNORE_SECONDARY_POLICIES" == "true" ]; then
        CANDIDATES=$(echo "$notready" | grep -v policy-acs | grep -v policy-advanced-managed-cluster-status | grep -v policy-hub-quay-bridge | grep -v policy-quay-status || true)
        if [ -z "$CANDIDATES" ]; then
          echo "Warning: Proceeding with OPP QE tests with some policy failures"
          exit 0
        else
          echo "Error policies failed to become compliant in allotted time, even considering the ignore list."
          exit 1
        fi
      else
        echo "Error policies failed to become compliant in allotted time."
        exit 1
      fi
    fi
    echo "Try ${try}/${RETRIES}: Policies are not compliant. Checking again in 30 seconds"
    sleep 30
  fi
done


 # 1. 检查 QuayRegistry 的 Clair 配置
  oc get quayregistry registry -n local-quay -o yaml | grep -A 10 "kind: clair"

  # 2. 检查实际 Clair pods 的资源规格
  POD=$(oc get pods -n local-quay -l quay-component=clair-app -o jsonpath='{.items[0].metadata.name}')
  oc get pod $POD -n local-quay -o json | \
    jq '.spec.containers[] | select(.name=="clair-app") | .resources'

  # 3. 如果发现 pods 还是 2Gi/2CPU，强制重建：
  #oc delete pods -n local-quay -l quay-component=clair-app
