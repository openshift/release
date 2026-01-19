#!/bin/bash

# Script to get the prior minor version for a given OpenShift version
# Usage: ./get_prior_minor_version.sh <version>
# Example: ./get_prior_minor_version.sh 4.21
# Output: 4.20

set -euo pipefail

# Function to display usage
usage() {
    echo "Usage: $0 <version>"
    echo "Example: $0 4.21"
    echo "Output: 4.20"
    exit 1
}

# Check if version argument is provided
if [ $# -eq 0 ]; then
    echo "Error: No version provided"
    usage
fi

VERSION="$1"

# Validate version format (should be X.Y)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Invalid version format. Expected format: X.Y (e.g., 4.21)"
    exit 1
fi

# Extract major and minor version numbers
MAJOR=$(echo "$VERSION" | cut -d. -f1)
MINOR=$(echo "$VERSION" | cut -d. -f2)

# Calculate prior minor version
PRIOR_MINOR=$((MINOR - 1))

# Check if prior minor is valid (non-negative)
if [ "$PRIOR_MINOR" -lt 0 ]; then
    echo "Error: No prior minor version for $VERSION (minor version is already 0)"
    exit 1
fi

# Output the prior minor version
echo "${MAJOR}.${PRIOR_MINOR}"

