#!/bin/bash

set -o nounset
export REPORT_HANDLE_PATH="/usr/bin"

pwd
echo "Quay upgrade test..."
oc version

#Deploy ODF Operator to OCP namespace 'openshift-storage'
OO_INSTALL_NAMESPACE=openshift-storage
# QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
# QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"
ODF_OPERATOR_CHANNEL="$ODF_OPERATOR_CHANNEL"
ODF_SUBSCRIPTION_NAME="$ODF_SUBSCRIPTION_NAME"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
EOF

OPERATORGROUP=$(oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup -o jsonpath="{.items[*].metadata.name}" || true)
if [[ -n "$OPERATORGROUP" ]]; then
  echo "OperatorGroup \"$OPERATORGROUP\" exists: modifying it"
  OG_OPERATION=apply
  OG_NAMESTANZA="name: $OPERATORGROUP"
else
  echo "OperatorGroup does not exist: creating it"
  OG_OPERATION=create
  OG_NAMESTANZA="generateName: oo-"
fi

OPERATORGROUP=$(
  oc $OG_OPERATION -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  $OG_NAMESTANZA
  namespace: $OO_INSTALL_NAMESPACE
spec:
  targetNamespaces: [$OO_INSTALL_NAMESPACE]
EOF
)

SUB=$(
  cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $ODF_SUBSCRIPTION_NAME
  namespace: $OO_INSTALL_NAMESPACE
spec:
  channel: $ODF_OPERATOR_CHANNEL
  installPlanApproval: Automatic
  name: $ODF_SUBSCRIPTION_NAME
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
)

for _ in {1..60}; do
  CSV=$(oc -n "$OO_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
  if [[ -n "$CSV" ]]; then
    if [[ "$(oc -n "$OO_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
      echo "ClusterServiceVersion \"$CSV\" ready"
      break
    fi
  fi
  sleep 10
done
echo "ODF/OCS Operator is deployed successfully"

cat <<EOF | oc apply -f -
apiVersion: noobaa.io/v1alpha1
kind: NooBaa
metadata:
  name: noobaa
  namespace: openshift-storage
spec:
  dbResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
  coreResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
  dbType: postgres
EOF

echo "Waiting for NooBaa Storage to be ready..." >&2
oc -n openshift-storage wait noobaa.noobaa.io/noobaa --for=condition=Available --timeout=180s

#export env variabels for Go test cases
export QUAY_OPERATOR_CHANNEL=${QUAY_OPERATOR_CHANNEL}
export QUAY_INDEX_IMAGE_BUILD=${QUAY_INDEX_IMAGE_BUILD}
export QUAYREGISTRY_QUAY_VERSION=${QUAYREGISTRY_QUAY_VERSION}

echo "Run extended-platform-tests"
extended-platform-tests run all --dry-run | grep -E ${QUAY_UPGRADE_TESTCASE} | extended-platform-tests run --timeout 240m --junit-dir="${ARTIFACT_DIR}" -f - || true


function handle_result {

  ## Correct ginkgo report numbers
    resultfile=`ls -rt -1 ${ARTIFACT_DIR}/junit_e2e_* 2>&1 || true`
    echo $resultfile
    if (echo $resultfile | grep -E "no matches found") || (echo $resultfile | grep -E "No such file or directory") ; then
        echo "there is no result file generated"
        return
    fi
    current_time=`date "+%Y-%m-%d-%H-%M-%S"`
    newresultfile="${ARTIFACT_DIR}/junit_e2e_${current_time}.xml"
    replace_ret=0
    python3 ${REPORT_HANDLE_PATH}/handleresult.py -a replace -i ${resultfile} -o ${newresultfile} || replace_ret=$?
    if ! [ "W${replace_ret}W" == "W0W" ]; then
        echo "replacing file is not ok"
        rm -fr ${resultfile}
        return
    fi 
    rm -fr ${resultfile}

    #Copy quay operator logs to ARTIFACT_DIR
    quayoperatorlogfile=`ls -rt -1 /tmp/*quayoperatorlogs.txt 2>&1 || true`
    echo $quayoperatorlogfile

    if (echo $quayoperatorlogfile | grep -E "no matches found") || (echo $quayoperatorlogfile | grep -E "No such file or directory") ; then
        echo "there is no operator log file generated"
        return
    fi
    cp $quayoperatorlogfile ${ARTIFACT_DIR}/ || true
 
}

handle_result