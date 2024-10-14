#!/bin/bash

set -o nounset
export REPORT_HANDLE_PATH="/usr/bin"

# echo "list generated shared resources"
# ls ${SHARED_DIR}
echo "working dir..." 
pwd

QUAY_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-aws-secret/access_key)
QUAY_AWS_SECRET_KEY=$(cat /var/run/quay-qe-aws-secret/secret_key)
QUAY_AWS_RDS_POSTGRESQL_DBNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/dbname)
QUAY_AWS_RDS_POSTGRESQL_USERNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/username)
QUAY_AWS_RDS_POSTGRESQL_PASSWORD=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/password)

QUAY_REDIS_IP_ADDRESS=$(cat ${SHARED_DIR}/QUAY_REDIS_IP_ADDRESS)
QUAY_AWS_RDS_POSTGRESQL_ADDRESS=$(cat ${SHARED_DIR}/QUAY_AWS_RDS_POSTGRESQL_ADDRESS)
QUAY_AWS_S3_BUCKET=$(cat ${SHARED_DIR}/QUAY_AWS_S3_BUCKET)
CLAIR_ROUTE_NAME=$(cat ${SHARED_DIR}/CLAIR_ROUTE_NAME)

#Deploy ODF Operator to OCP namespace 'openshift-storage'
OO_INSTALL_NAMESPACE=openshift-storage
QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"
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
export quayregistry_postgresql_db_hostname=${QUAY_AWS_RDS_POSTGRESQL_ADDRESS}
export quayregistry_postgresql_db_name=${QUAY_AWS_RDS_POSTGRESQL_DBNAME}
export quayregistry_postgresql_db_username=${QUAY_AWS_RDS_POSTGRESQL_USERNAME}
export quayregistry_postgresql_db_password=${QUAY_AWS_RDS_POSTGRESQL_PASSWORD}

export quayregistry_clair_scanner_endpoint=${CLAIR_ROUTE_NAME}

export quayregistry_aws_bucket_name=${QUAY_AWS_S3_BUCKET}
export quayregistry_aws_access_key=${QUAY_AWS_ACCESS_KEY}
export quayregistry_aws_secret_key=${QUAY_AWS_SECRET_KEY}

export quayregistry_redis_hostname=${QUAY_REDIS_IP_ADDRESS}
export quayregistry_redis_password=${quayregistry_postgresql_db_password} 

export QUAY_OPERATOR_CHANNEL=${QUAY_OPERATOR_CHANNEL}
export QUAY_INDEX_IMAGE_BUILD=${QUAY_INDEX_IMAGE_BUILD}

echo "Run extended-platform-tests" 
echo "..." $quayregistry_redis_hostname "... " $quayregistry_clair_scanner_endpoint "..." $quayregistry_postgresql_db_hostname

# extended-platform-tests run all --dry-run | grep -E "Quay-High|Quay-Medium"| extended-platform-tests run --timeout 150m --max-parallel-tests 3 --junit-dir="${ARTIFACT_DIR}" -f - || true
extended-platform-tests run all --dry-run | grep -E "Quay-Allns-Medium|Quay-Allns-High"| extended-platform-tests run --timeout 150m --max-parallel-tests 3 --junit-dir="${ARTIFACT_DIR}" -f - || true

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
 
}

handle_result