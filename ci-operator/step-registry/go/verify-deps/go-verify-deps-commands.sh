#!/bin/bash
set -o errexit # Nozero exit code of any of the commands below will fail the test.
set -o nounset
set -o pipefail

die_general() {
    echo "ERROR: An discrepancy was found in go dependency metadata. For example:"
    echo "- go.mod information may be incomplete."
    echo "- /vendor may not contain the versions declared in go.mod or certain"
    echo "  files which should be in /vendor have not been checked in. This can"
    echo "  happen due to .gitignore rules ignoring files in /vendor ."
    echo "- You may be trying to introduce a code change in vendored content. This"
    echo "  is not permitted (you should fork the upstream repository, introduce"
    echo "  the change in the fork, and vendor from the fork)."
    echo ""
    echo "Job logs show files that have been added or modified by running"
    echo "\"go mod tidy\" and \"go mod vendor\"".
    echo "You can run these commands locally and check for discrepancies with"
    echo "> git status --porcelain --ignored".
    echo ""
    echo "This check does not respect .gitignore entries. If .gitignore is masking"
    echo "files in vendor/, the check will fail. Update your .gitignore file to"
    echo "prevent it from acting on files in vendor/."
    echo ""
    echo "In order for the OpenShift Build and Release Team (ART) to create"
    echo "productized builds, all dependencies must be present and consistent."
    echo "Please correct these discrepancies before merging the PR."
    exit 1
}

die_modlist() {
    echo "ERROR: go list -mod=readonly -m all failed with the message listed above."
    echo "Cachito used in ART builds will fail to resolve dependencies offline."
    echo "Typically, a pinned version is missing in go.mod, e.g.:"
    echo "    replace k8s.io/foo => k8s.io/foo v0.26.0"
    exit 1
}

if [[ ! -f "go.mod" || ! -d "vendor" ]]; then
    echo "No go.mod vendoring detected in ${PWD}; skipping dependency checks."
    exit 0
else
    echo "Detected go.mod in ${PWD}; verifying vendored dependencies."
fi

# For debugging
go version

if [[ "${CHECK_MOD_LIST}" == "true" ]]; then
    echo "Checking that all modules can be resolved offline"
    go list -mod=readonly -m all || die_modlist
else
    echo "Skipping go mod list check"
fi

# Allow setting explicit -compat argument for go mod tidy
COMPAT=${COMPAT:-""}

echo "Checking that vendor/ is correct"
# If .gitignore exists, it can inhibit some files from being checked into /vendor. Remove it before
# vendoring to ensure there are no rules interfering with vendor/.
go mod tidy $COMPAT
go mod vendor
CHANGES=$(git status --porcelain --ignored)
if [ -n "$CHANGES" ] ; then
    echo "ERROR: detected vendor inconsistency after 'go mod tidy $COMPAT; go mod vendor':"
    echo "$CHANGES"
    die_general
fi
