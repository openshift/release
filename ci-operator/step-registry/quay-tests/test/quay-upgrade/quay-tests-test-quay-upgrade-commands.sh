#!/bin/bash

set -o nounset
export REPORT_HANDLE_PATH="/usr/bin"

pwd
echo "Quay upgrade test..."
oc version

#export env variabels for Go test cases
export QUAY_OPERATOR_CHANNEL=${QUAY_OPERATOR_CHANNEL}
export QUAY_INDEX_IMAGE_BUILD=${QUAY_INDEX_IMAGE_BUILD}
export CSO_INDEX_IMAGE_BUILD=${CSO_INDEX_IMAGE_BUILD}
export QUAY_VERSION=${QUAY_VERSION}

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