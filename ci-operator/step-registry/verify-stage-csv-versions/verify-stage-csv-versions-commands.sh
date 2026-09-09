#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function set_proxy() {
    if test -s "${SHARED_DIR}/proxy-conf.sh"; then
        source "${SHARED_DIR}/proxy-conf.sh"
    fi
}

function get_ocp_version() {
    OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
    OCP_MAJOR_MINOR=$(echo "${OCP_VERSION}" | cut -d '.' -f1,2)
    echo "Detected OCP version: ${OCP_VERSION} (major.minor: ${OCP_MAJOR_MINOR})"
}

set_proxy
get_ocp_version

REPORT_FILE="${ARTIFACT_DIR}/csv-version-check.log"
MISMATCH_COUNT=0
MATCH_COUNT=0
SKIP_COUNT=0

echo "==========================================" | tee "${REPORT_FILE}"
echo "CSV Version Check for CatalogSource: ${CATALOGSOURCE_NAME}" | tee -a "${REPORT_FILE}"
echo "Expected OCP version prefix: ${OCP_MAJOR_MINOR}." | tee -a "${REPORT_FILE}"
echo "==========================================" | tee -a "${REPORT_FILE}"
echo "" | tee -a "${REPORT_FILE}"

PACKAGES_JSON=$(oc get packagemanifests -n openshift-marketplace \
    -l "catalog=${CATALOGSOURCE_NAME}" -o json)

PACKAGE_COUNT=$(echo "${PACKAGES_JSON}" | jq '.items | length')

if [ "${PACKAGE_COUNT}" -eq 0 ]; then
    echo "ERROR: No packages found in CatalogSource ${CATALOGSOURCE_NAME}" | tee -a "${REPORT_FILE}"
    exit 1
fi

echo "Found ${PACKAGE_COUNT} packages in ${CATALOGSOURCE_NAME}" | tee -a "${REPORT_FILE}"
echo "" | tee -a "${REPORT_FILE}"

printf "%-45s %-35s %s\n" "PACKAGE" "CSV VERSION" "STATUS" | tee -a "${REPORT_FILE}"
printf "%-45s %-35s %s\n" "-------" "-----------" "------" | tee -a "${REPORT_FILE}"

for i in $(seq 0 $((PACKAGE_COUNT - 1))); do
    PACKAGE_NAME=$(echo "${PACKAGES_JSON}" | jq -r ".items[${i}].metadata.name")
    DEFAULT_CHANNEL=$(echo "${PACKAGES_JSON}" | jq -r ".items[${i}].status.defaultChannel")

    CSV_VERSION=$(echo "${PACKAGES_JSON}" | jq -r \
        ".items[${i}].status.channels[] | select(.name == \"${DEFAULT_CHANNEL}\") | .currentCSVDesc.version")

    if [ -z "${CSV_VERSION}" ] || [ "${CSV_VERSION}" = "null" ]; then
        printf "%-45s %-35s %s\n" "${PACKAGE_NAME}" "N/A" "SKIP" | tee -a "${REPORT_FILE}"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    if echo "${CSV_VERSION}" | grep -q "^${OCP_MAJOR_MINOR}\."; then
        printf "%-45s %-35s %s\n" "${PACKAGE_NAME}" "${CSV_VERSION}" "MATCH" | tee -a "${REPORT_FILE}"
        MATCH_COUNT=$((MATCH_COUNT + 1))
    else
        printf "%-45s %-35s %s\n" "${PACKAGE_NAME}" "${CSV_VERSION}" "MISMATCH" | tee -a "${REPORT_FILE}"
        MISMATCH_COUNT=$((MISMATCH_COUNT + 1))
    fi
done

echo "" | tee -a "${REPORT_FILE}"
echo "==========================================" | tee -a "${REPORT_FILE}"
echo "Results: ${MATCH_COUNT} match, ${MISMATCH_COUNT} mismatch, ${SKIP_COUNT} skipped (total: ${PACKAGE_COUNT})" | tee -a "${REPORT_FILE}"
echo "==========================================" | tee -a "${REPORT_FILE}"

if [ "${MISMATCH_COUNT}" -gt 0 ]; then
    echo "" | tee -a "${REPORT_FILE}"
    echo "FAILED: ${MISMATCH_COUNT} operator(s) have CSV versions that do not match OCP ${OCP_MAJOR_MINOR}" | tee -a "${REPORT_FILE}"
    exit 1
fi

echo "" | tee -a "${REPORT_FILE}"
echo "PASSED: All operator CSV versions match OCP ${OCP_MAJOR_MINOR}" | tee -a "${REPORT_FILE}"
