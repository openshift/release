#!/bin/bash
set -x

# Check if proxy is set
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  echo "Private cluster setting proxy"
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering extra artifacts."
	exit 0
fi

echo "Gathering node core dumps ..."

mkdir -p ${ARTIFACT_DIR}/core-dumps

oc adm must-gather --dest-dir="${ARTIFACT_DIR}/core-dumps" -- sh -c "/usr/bin/gather_core_dumps || true"

find ${ARTIFACT_DIR}/core-dumps/*/ -type f -name '*_core_dump'
CORE_DUMPS="$(find ${ARTIFACT_DIR}/core-dumps/*/ -type f -name '*_core_dump')"
num_core_dumps="$(echo -n "${CORE_DUMPS}" | grep -c "^" || true)"
echo "Found $num_core_dumps core dump files"

tar -czC "${ARTIFACT_DIR}/core-dumps" -f "${ARTIFACT_DIR}/core.dumps.tar.gz" .
ls -altrR ${ARTIFACT_DIR}
rm -rf "${ARTIFACT_DIR}/core-dumps"

# if there are any files collected from the core-dump gather and $FAIL_ON_CORE_DUMP is true then exit 1
# so the job can see it and be marked as a failure
if [ "${FAIL_ON_CORE_DUMP}" == "true" ]; then
  echo "${FAIL_ON_CORE_DUMP}"
  if [ $num_core_dumps -ne 0 ]; then
    echo "Fail: Found core dump files."
    mkdir -p ${ARTIFACT_DIR}/junit/
    cat >> ${ARTIFACT_DIR}/junit/junit_core_dump_status.xml << EOF
<testsuite name="gather core dump" tests="1" failures="1">
<testcase name="core files found">
<failure message="">
Fail: Found core dump files.
${CORE_DUMPS}
</failure>
</testcase>
</testsuite>
EOF
    exit 1
  else
    echo "No core dump files found."
    # successful junit, otherwise we can break aggregation when it does fail and we don't have passes to compare to
    mkdir -p ${ARTIFACT_DIR}/junit/
    cat >> ${ARTIFACT_DIR}/junit/junit_core_dump_status.xml << EOF
<testsuite name="gather core dump" tests="1" failures="0">
<testcase name="core files found">
</testcase>
</testsuite>
EOF
  fi
fi
