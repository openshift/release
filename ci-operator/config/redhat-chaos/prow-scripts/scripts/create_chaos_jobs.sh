#!/bin/bash

# Script to create chaos test configuration files for a new OpenShift version
# Usage: ./create_chaos_jobs.sh <target_version>
# Example: ./create_chaos_jobs.sh 4.21

set -e

TARGET_VERSION="$1"

if [ -z "$TARGET_VERSION" ]; then
    echo "Error: No target version provided"
    echo "Usage: $0 <target_version>"
    echo "Example: $0 4.21"
    exit 1
fi

PRIOR_VERSION=$(scripts/get_prior_minor_version.sh "$TARGET_VERSION")

# Extract version numbers for TicketId calculation
TARGET_MINOR=$(echo "$TARGET_VERSION" | cut -d. -f2)
PRIOR_MINOR=$(echo "$PRIOR_VERSION" | cut -d. -f2)

echo "Creating chaos test configurations for OCP ${TARGET_VERSION} based on ${PRIOR_VERSION}..."

# Create nightly chaos test config
NIGHTLY_SOURCE="redhat-chaos-prow-scripts-main__${PRIOR_VERSION}-nightly.yaml"
NIGHTLY_TARGET="redhat-chaos-prow-scripts-main__${TARGET_VERSION}-nightly.yaml"

if [ -f "$NIGHTLY_SOURCE" ]; then
    sed -e "s/\"${PRIOR_VERSION}\"/\"${TARGET_VERSION}\"/g" \
        -e "s/prow-ocp-${PRIOR_VERSION}/prow-ocp-${TARGET_VERSION}/g" \
        -e "s/prow-ocp-azure-${PRIOR_VERSION}/prow-ocp-azure-${TARGET_VERSION}/g" \
        -e "s/TicketId ${PRIOR_MINOR}[0-9]*/TicketId ${TARGET_MINOR}0/g" \
        -e "s/cerberus-main-prow-${PRIOR_MINOR}[0-9]*/cerberus-main-prow-${TARGET_MINOR}0/g" \
        -e "s/prow-scripts-${PRIOR_MINOR}[0-9]*/prow-scripts-${TARGET_MINOR}0/g" \
        -e "s/variant: ${PRIOR_VERSION}-nightly/variant: ${TARGET_VERSION}-nightly/g" \
        "$NIGHTLY_SOURCE" > "$NIGHTLY_TARGET"
    echo "Created: $NIGHTLY_TARGET"
else
    echo "Warning: Source file not found: $NIGHTLY_SOURCE"
fi

# Create ROSA chaos test config
ROSA_SOURCE="redhat-chaos-prow-scripts-main__rosa-${PRIOR_VERSION}-nightly.yaml"
ROSA_TARGET="redhat-chaos-prow-scripts-main__rosa-${TARGET_VERSION}-nightly.yaml"

if [ -f "$ROSA_SOURCE" ]; then
    sed -e "s/\"${PRIOR_VERSION}\"/\"${TARGET_VERSION}\"/g" \
        -e "s/OPENSHIFT_VERSION: \"${PRIOR_VERSION}\"/OPENSHIFT_VERSION: \"${TARGET_VERSION}\"/g" \
        -e "s/prow-rosa-${PRIOR_VERSION}/prow-rosa-${TARGET_VERSION}/g" \
        -e "s/TicketId:${PRIOR_MINOR}[0-9]*/TicketId:${TARGET_MINOR}0/g" \
        -e "s/cerberus-main-prow-rosa-${PRIOR_MINOR}[0-9]*/cerberus-main-prow-rosa-${TARGET_MINOR}0/g" \
        -e "s/variant: rosa-${PRIOR_VERSION}-nightly/variant: rosa-${TARGET_VERSION}-nightly/g" \
        "$ROSA_SOURCE" > "$ROSA_TARGET"
    echo "Created: $ROSA_TARGET"
else
    echo "Warning: Source file not found: $ROSA_SOURCE"
fi

# Create Component Readiness chaos test config
CR_SOURCE="redhat-chaos-prow-scripts-main__cr-${PRIOR_VERSION}-nightly.yaml"
CR_TARGET="redhat-chaos-prow-scripts-main__cr-${TARGET_VERSION}-nightly.yaml"

if [ -f "$CR_SOURCE" ]; then
    sed -e "s/\"${PRIOR_VERSION}\"/\"${TARGET_VERSION}\"/g" \
        -e "s/prow-ocp-${PRIOR_VERSION}-component-readiness/prow-ocp-${TARGET_VERSION}-component-readiness/g" \
        -e "s/TicketId ${PRIOR_MINOR}[0-9]*/TicketId ${TARGET_MINOR}0/g" \
        -e "s/cerberus-main-prow-${PRIOR_MINOR}[0-9]*/cerberus-main-prow-${TARGET_MINOR}0/g" \
        -e "s/variant: cr-${PRIOR_VERSION}-nightly/variant: cr-${TARGET_VERSION}-nightly/g" \
        "$CR_SOURCE" > "$CR_TARGET"
    echo "Created: $CR_TARGET"
else
    echo "Warning: Source file not found: $CR_SOURCE"
fi

echo ""
echo "Done! Created chaos test configurations for OCP ${TARGET_VERSION}"
echo ""
echo "Please verify the following in the new files:"
echo "  - Version references are correct"
echo "  - TELEMETRY_GROUP is updated"
echo "  - Image names reflect the new version"
echo "  - USER_TAGS/CLUSTER_TAGS TicketId is updated"

