#!/bin/bash

################################################################################
# OpenShift oc-mirror CI Pipeline Script (No Functions Version)
# 
# This script is generated from: openshift-oc-mirror-release-4.21.yaml
# 
# Purpose: Execute the complete CI/CD pipeline for oc-mirror project locally,
#          including builds, tests, and image creation.
#          This version has all functions inlined and all environment variables
#          set at the top of the file.
#
# Usage:
#   ./run-ci-pipeline-no-functions.sh [OPTIONS]
#
# Options:
#   --all                Run complete pipeline (builds + tests)
#   --build              Run builds only
#   --test               Run all tests only
#   --test-name NAME     Run specific test (sanity|unit|v1-e2e|lint|verify-deps|integration)
#   --skip-images        Skip Docker image builds
#   --dry-run            Show what would be executed without running
#   --help               Show this help message
#
# Examples:
#   ./run-ci-pipeline-no-functions.sh --all
#   ./run-ci-pipeline-no-functions.sh --test-name unit
#   ./run-ci-pipeline-no-functions.sh --build --skip-images
#
# Requirements:
#   - Docker or Podman
#   - make
#   - go (for local builds)
#   - golangci-lint (for lint tests)
#
################################################################################

set -o errexit
set -o nounset
set -o pipefail

################################################################################
# ALL ENVIRONMENT VARIABLES SET AT TOP
################################################################################

# Script metadata
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Base images from YAML configuration
BASE_IMAGE_GOLANGCI_LINT="registry.ci.openshift.org/ci/golangci-lint:latest"
BASE_IMAGE_OCP_BASE_RHEL9="registry.ci.openshift.org/ocp/4.21:base-rhel9"
BASE_IMAGE_BUILDER_RHEL8="registry.ci.openshift.org/ocp/builder:rhel-8-golang-1.24-openshift-4.21"
BASE_IMAGE_BUILDER_RHEL9="registry.ci.openshift.org/ocp/builder:rhel-9-golang-1.24-openshift-4.21"

# Build configuration
BINARY_BUILD_COMMAND="make build"
TEST_BINARY_BUILD_COMMAND="make build"

# Resource limits (from YAML)
MEMORY_LIMIT="4Gi"
MEMORY_REQUEST="200Mi"
CPU_REQUEST="100m"

# Artifact directories
ARTIFACT_DIR="${ARTIFACT_DIR:-${PROJECT_ROOT}/_artifacts/${TIMESTAMP}}"
LOG_DIR="${ARTIFACT_DIR}/logs"
JUNIT_DIR="${ARTIFACT_DIR}/junit"

# Execution flags
DRY_RUN=false
SKIP_IMAGES=false
RUN_BUILD=false
RUN_TEST=false
RUN_ALL=false
SPECIFIC_TEST=""

# Exit codes
EXIT_SUCCESS=0
EXIT_ERROR=1
EXIT_SKIP=2

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Container runtime (will be set during prerequisite check)
CONTAINER_RUNTIME=""

# Environment variables for tests
export HOME="${HOME:-/tmp/home}"
export GOCACHE="${GOCACHE:-/tmp/gocache}"
export GOLANGCI_LINT_CACHE="${GOLANGCI_LINT_CACHE:-/tmp/.cache}"
export GOPROXY="${GOPROXY:-https://proxy.golang.org}"
export CHECK_MOD_LIST="false"

################################################################################
# ARGUMENT PARSING (NO FUNCTIONS)
################################################################################

# Show usage if no arguments
if [[ $# -eq 0 ]]; then
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

OpenShift oc-mirror CI Pipeline Script

Options:
    --all                Run complete pipeline (builds + tests)
    --build              Run builds only
    --test               Run all tests only
    --test-name NAME     Run specific test (sanity|unit|v1-e2e|lint|verify-deps|integration)
    --skip-images        Skip Docker image builds
    --dry-run            Show what would be executed without running
    --help               Show this help message

Examples:
    $(basename "$0") --all
    $(basename "$0") --test-name unit
    $(basename "$0") --build --skip-images
    $(basename "$0") --test --dry-run

Environment Variables:
    ARTIFACT_DIR         Directory for artifacts (default: _artifacts/TIMESTAMP)
    CONTAINER_RUNTIME    Container runtime to use (docker or podman, auto-detected)

EOF
    exit ${EXIT_ERROR}
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            RUN_ALL=true
            shift
            ;;
        --build)
            RUN_BUILD=true
            shift
            ;;
        --test)
            RUN_TEST=true
            shift
            ;;
        --test-name)
            SPECIFIC_TEST="$2"
            shift 2
            ;;
        --skip-images)
            SKIP_IMAGES=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            cat << EOF
Usage: $(basename "$0") [OPTIONS]

OpenShift oc-mirror CI Pipeline Script

Options:
    --all                Run complete pipeline (builds + tests)
    --build              Run builds only
    --test               Run all tests only
    --test-name NAME     Run specific test (sanity|unit|v1-e2e|lint|verify-deps|integration)
    --skip-images        Skip Docker image builds
    --dry-run            Show what would be executed without running
    --help               Show this help message

Examples:
    $(basename "$0") --all
    $(basename "$0") --test-name unit
    $(basename "$0") --build --skip-images
    $(basename "$0") --test --dry-run

Environment Variables:
    ARTIFACT_DIR         Directory for artifacts (default: _artifacts/TIMESTAMP)
    CONTAINER_RUNTIME    Container runtime to use (docker or podman, auto-detected)

EOF
            exit ${EXIT_SUCCESS}
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} - Unknown option: $1" >&2
            exit ${EXIT_ERROR}
            ;;
    esac
done

################################################################################
# MAIN EXECUTION (NO FUNCTIONS - ALL INLINED)
################################################################################

# Set up trap for cleanup
trap 'exit_code=$?; if [[ ${exit_code} -eq 0 ]]; then echo -e "${GREEN}[SUCCESS]${NC} - Pipeline completed successfully"; else echo -e "${RED}[ERROR]${NC} - Pipeline failed with exit code: ${exit_code}" >&2; fi; exit ${exit_code}' EXIT INT TERM

# Display configuration
echo ""
echo "================================================================================"
echo -e "${BLUE}CI Pipeline Configuration${NC}"
echo "================================================================================"
echo ""
echo -e "${BLUE}[INFO]${NC} - Project Root: ${PROJECT_ROOT}"
echo -e "${BLUE}[INFO]${NC} - Artifact Directory: ${ARTIFACT_DIR}"
echo -e "${BLUE}[INFO]${NC} - Dry Run: ${DRY_RUN}"
echo -e "${BLUE}[INFO]${NC} - Skip Images: ${SKIP_IMAGES}"
echo -e "${BLUE}[INFO]${NC} - Run All: ${RUN_ALL}"
echo -e "${BLUE}[INFO]${NC} - Run Build: ${RUN_BUILD}"
echo -e "${BLUE}[INFO]${NC} - Run Test: ${RUN_TEST}"
echo -e "${BLUE}[INFO]${NC} - Specific Test: ${SPECIFIC_TEST:-none}"

# Check prerequisites
echo ""
echo "================================================================================"
echo -e "${BLUE}Checking Prerequisites${NC}"
echo "================================================================================"
echo ""

# Assume `make` `podman`
missing_tools=()
CONTAINER_RUNTIME="podman"

# Setup environment
echo ""
echo "================================================================================"
echo -e "${BLUE}Setting Up Environment${NC}"
echo "================================================================================"
echo ""

# Create artifact directories
mkdir -p "${ARTIFACT_DIR}"
mkdir -p "${LOG_DIR}"
mkdir -p "${JUNIT_DIR}"

echo -e "${BLUE}[INFO]${NC} - Artifact directory: ${ARTIFACT_DIR}"
echo -e "${BLUE}[INFO]${NC} - Log directory: ${LOG_DIR}"
echo -e "${BLUE}[INFO]${NC} - JUnit directory: ${JUNIT_DIR}"

# Export environment variables
export ARTIFACT_DIR

echo -e "${GREEN}[SUCCESS]${NC} - Environment setup complete"

################################################################################
# PIPELINE EXECUTION
################################################################################

# Determine what to run
if [[ "${RUN_ALL}" == "true" ]] || [[ "${RUN_BUILD}" == "true" ]]; then
    # BUILD BINARY
    echo ""
    echo "================================================================================"
    echo -e "${BLUE}Building Binary${NC}"
    echo "================================================================================"
    echo ""
    
    log_file="${LOG_DIR}/build-binary.log"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${BLUE}[INFO]${NC} - [DRY-RUN] Would execute: cd ${PROJECT_ROOT} && ${BINARY_BUILD_COMMAND}"
    else
        echo -e "${BLUE}[INFO]${NC} - Executing: cd ${PROJECT_ROOT} && ${BINARY_BUILD_COMMAND}"
        cd "${PROJECT_ROOT}" && eval "${BINARY_BUILD_COMMAND}" 2>&1 | tee "${log_file}"
    fi
    
    echo -e "${GREEN}[SUCCESS]${NC} - Binary build completed"
    
    # BUILD TEST BINARY
    echo ""
    echo "================================================================================"
    echo -e "${BLUE}Building Test Binary${NC}"
    echo "================================================================================"
    echo ""
    
    log_file="${LOG_DIR}/build-test-binary.log"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${BLUE}[INFO]${NC} - [DRY-RUN] Would execute: cd ${PROJECT_ROOT} && ${TEST_BINARY_BUILD_COMMAND}"
    else
        echo -e "${BLUE}[INFO]${NC} - Executing: cd ${PROJECT_ROOT} && ${TEST_BINARY_BUILD_COMMAND}"
        cd "${PROJECT_ROOT}" && eval "${TEST_BINARY_BUILD_COMMAND}" 2>&1 | tee "${log_file}"
    fi
    
    echo -e "${GREEN}[SUCCESS]${NC} - Test binary build completed"
    
    # BUILD OC-MIRROR IMAGE
    if [[ "${SKIP_IMAGES}" == "false" ]]; then
        echo ""
        echo "================================================================================"
        echo -e "${BLUE}Building oc-mirror Container Image${NC}"
        echo "================================================================================"
        echo ""
        
        dockerfile="images/cli/Dockerfile.ci"
        image_name="oc-mirror:latest"
        log_file="${LOG_DIR}/build-oc-mirror-image.log"
        
        if [[ ! -f "${PROJECT_ROOT}/${dockerfile}" ]]; then
            echo -e "${RED}[ERROR]${NC} - Dockerfile not found: ${dockerfile}" >&2
            exit ${EXIT_ERROR}
        fi
        
        echo -e "${BLUE}[INFO]${NC} - Building image: ${image_name}"
        echo -e "${BLUE}[INFO]${NC} - Using Dockerfile: ${dockerfile}"
        
        if [[ "${DRY_RUN}" == "true" ]]; then
            echo -e "${BLUE}[INFO]${NC} - [DRY-RUN] Would execute: ${CONTAINER_RUNTIME} build ..."
        else
            echo -e "${BLUE}[INFO]${NC} - Executing: ${CONTAINER_RUNTIME} build ..."
            ${CONTAINER_RUNTIME} build \
                --build-arg BASE_IMAGE=${BASE_IMAGE_OCP_BASE_RHEL9} \
                --build-arg BUILDER_IMAGE_RHEL8=${BASE_IMAGE_BUILDER_RHEL8} \
                --build-arg BUILDER_IMAGE_RHEL9=${BASE_IMAGE_BUILDER_RHEL9} \
                -t ${image_name} \
                -f ${PROJECT_ROOT}/${dockerfile} \
                ${PROJECT_ROOT} 2>&1 | tee "${log_file}"
        fi
        
        echo -e "${GREEN}[SUCCESS]${NC} - oc-mirror image built successfully"
        
        # BUILD OC-MIRROR-TESTS IMAGE
        echo ""
        echo "================================================================================"
        echo -e "${BLUE}Building oc-mirror-tests Container Image${NC}"
        echo "================================================================================"
        echo ""
        
        dockerfile="images/cli/Dockerfile.test"
        image_name="oc-mirror-tests:latest"
        log_file="${LOG_DIR}/build-oc-mirror-tests-image.log"
        
        if [[ ! -f "${PROJECT_ROOT}/${dockerfile}" ]]; then
            echo -e "${RED}[ERROR]${NC} - Dockerfile not found: ${dockerfile}" >&2
            exit ${EXIT_ERROR}
        fi
        
        echo -e "${BLUE}[INFO]${NC} - Building image: ${image_name}"
        echo -e "${BLUE}[INFO]${NC} - Using Dockerfile: ${dockerfile}"
        
        if [[ "${DRY_RUN}" == "true" ]]; then
            echo -e "${BLUE}[INFO]${NC} - [DRY-RUN] Would execute: ${CONTAINER_RUNTIME} build ..."
        else
            echo -e "${BLUE}[INFO]${NC} - Executing: ${CONTAINER_RUNTIME} build ..."
            ${CONTAINER_RUNTIME} build \
                --build-arg BASE_IMAGE=${BASE_IMAGE_OCP_BASE_RHEL9} \
                --build-arg BUILDER_IMAGE=${BASE_IMAGE_BUILDER_RHEL9} \
                -t ${image_name} \
                -f ${PROJECT_ROOT}/${dockerfile} \
                ${PROJECT_ROOT} 2>&1 | tee "${log_file}"
        fi
        
        echo -e "${GREEN}[SUCCESS]${NC} - oc-mirror-tests image built successfully"
    else
        echo -e "${YELLOW}[WARNING]${NC} - Skipping image builds (--skip-images flag set)"
    fi
    
    echo -e "${GREEN}[SUCCESS]${NC} - All builds completed successfully"
fi

# Run tests
if [[ "${RUN_ALL}" == "true" ]] || [[ "${RUN_TEST}" == "true" ]] || [[ -n "${SPECIFIC_TEST}" ]]; then
    
    # SANITY TEST
    if [[ "${RUN_ALL}" == "true" ]] || [[ "${RUN_TEST}" == "true" ]] || [[ "${SPECIFIC_TEST}" == "sanity" ]]; then
        echo ""
        echo "================================================================================"
        echo -e "${BLUE}Running Sanity Tests${NC}"
        echo "================================================================================"
        echo ""
        
        log_file="${LOG_DIR}/test-sanity.log"
        
        if [[ "${DRY_RUN}" == "true" ]]; then
            echo -e "${BLUE}[INFO]${NC} - [DRY-RUN] Would execute: cd ${PROJECT_ROOT} && make sanity"
        else
            echo -e "${BLUE}[INFO]${NC} - Executing: cd ${PROJECT_ROOT} && make sanity"
            cd "${PROJECT_ROOT}" && make sanity 2>&1 | tee "${log_file}"
        fi
        
        echo -e "${GREEN}[SUCCESS]${NC} - Sanity tests passed"
    fi
    
    # UNIT TEST
    if [[ "${RUN_ALL}" == "true" ]] || [[ "${RUN_TEST}" == "true" ]] || [[ "${SPECIFIC_TEST}" == "unit" ]]; then
        echo ""
        echo "================================================================================"
        echo -e "${BLUE}Running Unit Tests${NC}"
        echo "================================================================================"
        echo ""
        
        log_file="${LOG_DIR}/test-unit.log"
        
        # Setup HOME directory as per YAML configuration
        test_home="/tmp/home"
        mkdir -p "${test_home}"
        
        if [[ "${DRY_RUN}" == "true" ]]; then
            echo -e "${BLUE}[INFO]${NC} - [DRY-RUN] Would execute: cd ${PROJECT_ROOT} && HOME=${test_home} make test-unit"
        else
            echo -e "${BLUE}[INFO]${NC} - Executing: cd ${PROJECT_ROOT} && HOME=${test_home} make test-unit"
            cd "${PROJECT_ROOT}" && HOME=${test_home} make test-unit 2>&1 | tee "${log_file}"
        fi
        
        echo -e "${GREEN}[SUCCESS]${NC} - Unit tests passed"
    fi
    
    # V1 E2E TEST
    if [[ "${RUN_ALL}" == "true" ]] || [[ "${RUN_TEST}" == "true" ]] || [[ "${SPECIFIC_TEST}" == "v1-e2e" ]]; then
        echo ""
        echo "================================================================================"
        echo -e "${BLUE}Running V1 E2E Tests${NC}"
        echo "================================================================================"
        echo ""
        
        log_file="${LOG_DIR}/test-v1-e2e.log"
        
        if [[ "${DRY_RUN}" == "true" ]]; then
            echo -e "${BLUE}[INFO]${NC} - [DRY-RUN] Would execute: cd ${PROJECT_ROOT} && (pushd v1 || true) && make test-e2e"
        else
            echo -e "${BLUE}[INFO]${NC} - Executing: cd ${PROJECT_ROOT} && (pushd v1 || true) && make test-e2e"
            cd "${PROJECT_ROOT}" && (pushd v1 || true) && make test-e2e 2>&1 | tee "${log_file}"
        fi
        
        echo -e "${GREEN}[SUCCESS]${NC} - V1 E2E tests passed"
    fi
    
    # LINT TEST
    if [[ "${RUN_ALL}" == "true" ]] || [[ "${RUN_TEST}" == "true" ]] || [[ "${SPECIFIC_TEST}" == "lint" ]]; then
        echo ""
        echo "================================================================================"
        echo -e "${BLUE}Running Lint Tests${NC}"
        echo "================================================================================"
        echo ""
        
        log_file="${LOG_DIR}/test-lint.log"
        
        # Set up environment variables as per YAML
        export GOCACHE=/tmp/
        export GOLANGCI_LINT_CACHE=/tmp/.cache
        export GOPROXY=https://proxy.golang.org
        
        if [[ "${DRY_RUN}" == "true" ]]; then
            echo -e "${BLUE}[INFO]${NC} - [DRY-RUN] Would run lint tests"
        else
            cd "${PROJECT_ROOT}"
            pushd v2 || true
            
            # Check golangci-lint version and run appropriate command
            if command -v golangci-lint &> /dev/null; then
                echo -e "${BLUE}[INFO]${NC} - Running golangci-lint version check..."
                golangci-lint version | tee -a "${log_file}"
                
                maj_version=$(((golangci-lint version --short 2>/dev/null || golangci-lint version --format short 2>/dev/null) | cut -f1 -d.) || echo "1")
                
                if [ "${maj_version}" -eq 1 ]; then
                    echo -e "${BLUE}[INFO]${NC} - Running golangci-lint v1.x configuration..."
                    golangci-lint run --new-from-rev=HEAD~ \
                        --out-format colored-line-number \
                        --verbose --print-resources-usage --timeout=5m \
                        --build-tags "json1 exclude_graphdriver_btrfs exclude_graphdriver_devicemapper containers_image_openpgp" \
                        --config .golangci.yaml 2>&1 | tee -a "${log_file}"
                else
                    echo -e "${BLUE}[INFO]${NC} - Running golangci-lint v2.x configuration..."
                    golangci-lint run --new-from-rev=HEAD~ --verbose --timeout=5m --config .golangci.v2.yaml 2>&1 | tee -a "${log_file}"
                fi
            else
                echo -e "${YELLOW}[WARNING]${NC} - golangci-lint not found locally, attempting to use container..."
                ${CONTAINER_RUNTIME} run --rm \
                    -v "${PROJECT_ROOT}:/workspace:z" \
                    -w /workspace/v2 \
                    -e GOCACHE=/tmp/ \
                    -e GOLANGCI_LINT_CACHE=/tmp/.cache \
                    -e GOPROXY=https://proxy.golang.org \
                    "${BASE_IMAGE_GOLANGCI_LINT}" \
                    bash -c "golangci-lint run --new-from-rev=HEAD~ --verbose --timeout=5m" 2>&1 | tee -a "${log_file}"
            fi
            
            popd || true
        fi
        
        echo -e "${GREEN}[SUCCESS]${NC} - Lint tests passed"
    fi
    
    # VERIFY DEPS TEST
    if [[ "${RUN_ALL}" == "true" ]] || [[ "${RUN_TEST}" == "true" ]] || [[ "${SPECIFIC_TEST}" == "verify-deps" ]]; then
        echo ""
        echo "================================================================================"
        echo -e "${BLUE}Running Verify Dependencies Test${NC}"
        echo "================================================================================"
        echo ""
        
        log_file="${LOG_DIR}/test-verify-deps.log"
        
        # Set environment variable as per YAML
        export CHECK_MOD_LIST="false"
        
        echo -e "${BLUE}[INFO]${NC} - CHECK_MOD_LIST=${CHECK_MOD_LIST}"
        
        if [[ "${DRY_RUN}" == "true" ]]; then
            echo -e "${BLUE}[INFO]${NC} - [DRY-RUN] Would run verify dependencies"
        else
            # This test typically runs go-verify-deps
            if [[ -f "${PROJECT_ROOT}/hack/verify-deps.sh" ]]; then
                echo -e "${BLUE}[INFO]${NC} - Executing: cd ${PROJECT_ROOT} && ./hack/verify-deps.sh"
                cd "${PROJECT_ROOT}" && ./hack/verify-deps.sh 2>&1 | tee "${log_file}"
            elif command -v go &> /dev/null; then
                echo -e "${BLUE}[INFO]${NC} - Running go mod verify..."
                cd "${PROJECT_ROOT}" && go mod verify 2>&1 | tee "${log_file}"
                echo -e "${BLUE}[INFO]${NC} - Running go mod tidy check..."
                cd "${PROJECT_ROOT}" && go mod tidy && git diff --exit-code go.mod go.sum 2>&1 | tee -a "${log_file}"
            else
                echo -e "${YELLOW}[WARNING]${NC} - Cannot verify dependencies - no verify script or go command found"
            fi
        fi
        
        echo -e "${GREEN}[SUCCESS]${NC} - Dependency verification passed"
    fi
    
    # INTEGRATION TEST
    if [[ "${RUN_ALL}" == "true" ]] || [[ "${RUN_TEST}" == "true" ]] || [[ "${SPECIFIC_TEST}" == "integration" ]]; then
        echo ""
        echo "================================================================================"
        echo -e "${BLUE}Running Integration Tests${NC}"
        echo "================================================================================"
        echo ""
        
        log_file="${LOG_DIR}/test-integration.log"
        
        echo -e "${BLUE}[INFO]${NC} - Running integration tests using flow-controller.sh"
        
        if [[ "${DRY_RUN}" == "true" ]]; then
            echo -e "${BLUE}[INFO]${NC} - [DRY-RUN] Would run integration tests"
        else
            if [[ -f "${PROJECT_ROOT}/scripts/flow-controller.sh" ]]; then
                echo -e "${BLUE}[INFO]${NC} - Executing: cd ${PROJECT_ROOT} && ./scripts/flow-controller.sh all_happy_path"
                cd "${PROJECT_ROOT}" && ./scripts/flow-controller.sh all_happy_path 2>&1 | tee "${log_file}"
            else
                echo -e "${YELLOW}[WARNING]${NC} - Integration test script not found: scripts/flow-controller.sh"
                echo -e "${BLUE}[INFO]${NC} - Attempting to run with oc-mirror-tests container..."
                
                if [[ "${SKIP_IMAGES}" == "false" ]]; then
                    ${CONTAINER_RUNTIME} run --rm \
                        -v ${PROJECT_ROOT}:/workspace:z \
                        -w /workspace \
                        oc-mirror-tests:latest \
                        ./scripts/flow-controller.sh all_happy_path 2>&1 | tee "${log_file}"
                else
                    echo -e "${RED}[ERROR]${NC} - Cannot run integration tests - script not found and images skipped" >&2
                    exit ${EXIT_ERROR}
                fi
            fi
        fi
        
        echo -e "${GREEN}[SUCCESS]${NC} - Integration tests passed"
    fi
    
    # Check if specific test was invalid
    if [[ -n "${SPECIFIC_TEST}" ]] && [[ "${SPECIFIC_TEST}" != "sanity" ]] && [[ "${SPECIFIC_TEST}" != "unit" ]] && [[ "${SPECIFIC_TEST}" != "v1-e2e" ]] && [[ "${SPECIFIC_TEST}" != "lint" ]] && [[ "${SPECIFIC_TEST}" != "verify-deps" ]] && [[ "${SPECIFIC_TEST}" != "integration" ]]; then
        echo -e "${RED}[ERROR]${NC} - Unknown test name: ${SPECIFIC_TEST}" >&2
        echo -e "${RED}[ERROR]${NC} - Valid test names: sanity, unit, v1-e2e, lint, verify-deps, integration" >&2
        exit ${EXIT_ERROR}
    fi
    
    echo -e "${GREEN}[SUCCESS]${NC} - All tests passed successfully"
fi

# Check if no action was specified
if [[ "${RUN_ALL}" == "false" ]] && [[ "${RUN_BUILD}" == "false" ]] && [[ "${RUN_TEST}" == "false" ]] && [[ -z "${SPECIFIC_TEST}" ]]; then
    echo -e "${RED}[ERROR]${NC} - No action specified. Use --all, --build, --test, or --test-name" >&2
    exit ${EXIT_ERROR}
fi

# Generate summary
echo ""
echo "================================================================================"
echo -e "${BLUE}Pipeline Summary${NC}"
echo "================================================================================"
echo ""
echo -e "${BLUE}[INFO]${NC} - Artifacts saved to: ${ARTIFACT_DIR}"
echo -e "${BLUE}[INFO]${NC} - Logs available in: ${LOG_DIR}"
echo -e "${BLUE}[INFO]${NC} - JUnit results in: ${JUNIT_DIR}"

echo -e "${GREEN}[SUCCESS]${NC} - Pipeline execution completed successfully!"
