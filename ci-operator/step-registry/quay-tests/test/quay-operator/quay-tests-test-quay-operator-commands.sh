#!/bin/bash

set -o nounset
export REPORT_HANDLE_PATH="/usr/bin"

QUAY_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-aws-secret/access_key)
QUAY_AWS_SECRET_KEY=$(cat /var/run/quay-qe-aws-secret/secret_key)
QUAY_AWS_RDS_POSTGRESQL_DBNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/dbname)
QUAY_AWS_RDS_POSTGRESQL_USERNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/username)
QUAY_AWS_RDS_POSTGRESQL_PASSWORD=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/password)

# env variables from shared dir for single ns test cases
QUAY_REDIS_IP_ADDRESS=$([ -f "${SHARED_DIR}/QUAY_REDIS_IP_ADDRESS" ] && cat "${SHARED_DIR}/QUAY_REDIS_IP_ADDRESS" || echo "")
QUAY_AWS_RDS_POSTGRESQL_ADDRESS=$([ -f "${SHARED_DIR}/QUAY_AWS_RDS_POSTGRESQL_ADDRESS" ] && cat "${SHARED_DIR}/QUAY_AWS_RDS_POSTGRESQL_ADDRESS" || echo "") 
QUAY_AWS_S3_BUCKET=$([ -f "${SHARED_DIR}/QUAY_AWS_S3_BUCKET" ] && cat "${SHARED_DIR}/QUAY_AWS_S3_BUCKET" || echo "")
CLAIR_ROUTE_NAME=$([ -f "${SHARED_DIR}/CLAIR_ROUTE_NAME" ] && cat "${SHARED_DIR}/CLAIR_ROUTE_NAME" || echo "")

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

# QUAY_OPERATOR_TESTCASE: Quay-Allns-Medium|Quay-Allns-High, Quay-High|Quay-Medium
extended-platform-tests run all --dry-run | grep -E ${QUAY_OPERATOR_TESTCASE} | extended-platform-tests run --timeout 150m --max-parallel-tests 3 --junit-dir="${ARTIFACT_DIR}" -f - || true

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