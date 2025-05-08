#!/bin/bash
set -o errexit # Nozero exit code of any of the commands below will fail the test.
set -o nounset
set -o pipefail

die_general() {
    echo "ERROR: An discrepancy was found in go dependency metadata or it could not"
    echo "be checked successfully. Common failures:"
    echo "- go mod tidy failed to run with the repository's configured \"build root\"."
    echo "  Errors output like 'go.mod file indicates go 1.21, but maximum supported version is 1.17'"
    echo "  indicate your go.mod requests 1.21, but your Test Platform build root is based"
    echo "  on a go 1.17 builder image. The following documentation explains build root configuration:"
    echo "  https://docs.ci.openshift.org/docs/architecture/images/#controlling-go-versions-in-component-repositories"
    echo "  Generally, you will want 'build_root.from_repository: true' in your"
    echo "  ci-operator configuration file and to manage your build root in your component"
    echo "  repository in .ci-operator.yaml (.ci-operator.yaml is ignored if from_repository: true"
    echo "  is not set)."
    echo ""
    echo "- go.mod information may be incomplete / inaccurate."
    echo ""
    echo "- /vendor may not contain the versions declared in go.mod or certain"
    echo "  files which should be in /vendor have not been checked in. This can"
    echo "  happen due to .gitignore rules ignoring files in /vendor ."
    echo ""
    echo "- You may be trying to introduce a code change in vendored content. This"
    echo "  is not permitted. If you must make custom changes to a module,"
    echo "  there are two options:"
    echo "  1. Use a local go.mod replace statement. For example:"
    echo "     replace example.com/foo/bar => ../bar-modified"
    echo "  2. When multiple repositories need the same modification, it may prove easier"
    echo "     to fork the upstream dependency into github.com/openshift, customize"
    echo "     a branch, and vendor the fork in your go.mod. For example:"
    echo "     https://github.com/openshift/golang-crypto/tree/patch_v0.33.openshift.1"
    echo ""
    echo "Job logs show files that have been added or modified by running"
    echo "\"go mod tidy\" and \"go mod vendor\" (or \"go work vendor\" for workspaces)."
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

echo "Running: go mod tidy $COMPAT"
go mod tidy $COMPAT

VENDOR_MODE="mod"
if [[ -f "go.work" && "${GOWORK:-}" != "off" ]]; then
  echo "Detected go workspace; using \"go work vendor\"."
  VENDOR_MODE="work"
fi

echo "Running: go ${VENDOR_MODE} vendor"
go "${VENDOR_MODE}" vendor

# If .gitignore exists, it can inhibit some files from being checked into /vendor. "--ignored"
# ensures that .gitignore is NOT honored during comparison.
CHANGES=$(git status --porcelain --ignored)
if [ -n "$CHANGES" ] ; then
    echo "ERROR: detected vendor inconsistency after 'go mod tidy $COMPAT; go ${VENDOR_MODE} vendor':"
    echo "$CHANGES"
    die_general
fi
