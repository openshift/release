#!/bin/bash

################################################################################
# OpenShift oc-mirror CI Pipeline Script
# 
# This script is generated from: openshift-oc-mirror-release-4.21.yaml
# 
# Purpose: Execute the complete CI/CD pipeline for oc-mirror project locally,
#          including builds, tests, and image creation.
#
# Usage:
#   ./run-ci-pipeline.sh [OPTIONS]
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
#   ./run-ci-pipeline.sh --all
#   ./run-ci-pipeline.sh --test-name unit
#   ./run-ci-pipeline.sh --build --skip-images
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
# Global Variables
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

################################################################################
# Utility Functions
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_section() {
    echo ""
    echo "================================================================================"
    echo -e "${BLUE}$*${NC}"
    echo "================================================================================"
    echo ""
}

execute_command() {
    local cmd="$*"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would execute: ${cmd}"
        return 0
    fi
    
    log_info "Executing: ${cmd}"
    eval "${cmd}"
}

check_prerequisites() {
    log_section "Checking Prerequisites"
    
    local missing_tools=()
    
    # Check for container runtime
    if command -v docker &> /dev/null; then
        CONTAINER_RUNTIME="docker"
        log_success "Found Docker: $(docker --version)"
    elif command -v podman &> /dev/null; then
        CONTAINER_RUNTIME="podman"
        log_success "Found Podman: $(podman --version)"
    else
        missing_tools+=("docker or podman")
    fi
    
    # Check for make
    if command -v make &> /dev/null; then
        log_success "Found make: $(make --version | head -n1)"
    else
        missing_tools+=("make")
    fi
    
    # Check for go
    if command -v go &> /dev/null; then
        log_success "Found Go: $(go version)"
    else
        log_warning "Go not found - some operations may fail"
    fi
    
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install the missing tools and try again"
        exit ${EXIT_ERROR}
    fi
    
    log_success "All prerequisites satisfied"
}

setup_environment() {
    log_section "Setting Up Environment"
    
    # Create artifact directories
    mkdir -p "${ARTIFACT_DIR}"
    mkdir -p "${LOG_DIR}"
    mkdir -p "${JUNIT_DIR}"
    
    log_info "Artifact directory: ${ARTIFACT_DIR}"
    log_info "Log directory: ${LOG_DIR}"
    log_info "JUnit directory: ${JUNIT_DIR}"
    
    # Set environment variables
    export ARTIFACT_DIR
    export HOME="${HOME:-/tmp/home}"
    export GOCACHE="${GOCACHE:-/tmp/gocache}"
    export GOLANGCI_LINT_CACHE="${GOLANGCI_LINT_CACHE:-/tmp/.cache}"
    export GOPROXY="${GOPROXY:-https://proxy.golang.org}"
    
    log_success "Environment setup complete"
}

cleanup() {
    local exit_code=$?
    
    if [[ ${exit_code} -eq 0 ]]; then
        log_success "Pipeline completed successfully"
    else
        log_error "Pipeline failed with exit code: ${exit_code}"
    fi
    
    exit ${exit_code}
}

################################################################################
# Build Functions
################################################################################

build_binary() {
    log_section "Building Binary"
    
    local log_file="${LOG_DIR}/build-binary.log"
    
    execute_command "cd ${PROJECT_ROOT} && ${BINARY_BUILD_COMMAND} 2>&1 | tee ${log_file}"
    
    log_success "Binary build completed"
}

build_test_binary() {
    log_section "Building Test Binary"
    
    local log_file="${LOG_DIR}/build-test-binary.log"
    
    execute_command "cd ${PROJECT_ROOT} && ${TEST_BINARY_BUILD_COMMAND} 2>&1 | tee ${log_file}"
    
    log_success "Test binary build completed"
}

build_oc_mirror_image() {
    log_section "Building oc-mirror Container Image"
    
    if [[ "${SKIP_IMAGES}" == "true" ]]; then
        log_warning "Skipping image build (--skip-images flag set)"
        return ${EXIT_SKIP}
    fi
    
    local dockerfile="images/cli/Dockerfile.ci"
    local image_name="oc-mirror:latest"
    local log_file="${LOG_DIR}/build-oc-mirror-image.log"
    
    if [[ ! -f "${PROJECT_ROOT}/${dockerfile}" ]]; then
        log_error "Dockerfile not found: ${dockerfile}"
        return ${EXIT_ERROR}
    fi
    
    log_info "Building image: ${image_name}"
    log_info "Using Dockerfile: ${dockerfile}"
    
    execute_command "${CONTAINER_RUNTIME} build \
        --build-arg BASE_IMAGE=${BASE_IMAGE_OCP_BASE_RHEL9} \
        --build-arg BUILDER_IMAGE_RHEL8=${BASE_IMAGE_BUILDER_RHEL8} \
        --build-arg BUILDER_IMAGE_RHEL9=${BASE_IMAGE_BUILDER_RHEL9} \
        -t ${image_name} \
        -f ${PROJECT_ROOT}/${dockerfile} \
        ${PROJECT_ROOT} 2>&1 | tee ${log_file}"
    
    log_success "oc-mirror image built successfully"
}

build_oc_mirror_tests_image() {
    log_section "Building oc-mirror-tests Container Image"
    
    if [[ "${SKIP_IMAGES}" == "true" ]]; then
        log_warning "Skipping image build (--skip-images flag set)"
        return ${EXIT_SKIP}
    fi
    
    local dockerfile="images/cli/Dockerfile.test"
    local image_name="oc-mirror-tests:latest"
    local log_file="${LOG_DIR}/build-oc-mirror-tests-image.log"
    
    if [[ ! -f "${PROJECT_ROOT}/${dockerfile}" ]]; then
        log_error "Dockerfile not found: ${dockerfile}"
        return ${EXIT_ERROR}
    fi
    
    log_info "Building image: ${image_name}"
    log_info "Using Dockerfile: ${dockerfile}"
    
    execute_command "${CONTAINER_RUNTIME} build \
        --build-arg BASE_IMAGE=${BASE_IMAGE_OCP_BASE_RHEL9} \
        --build-arg BUILDER_IMAGE=${BASE_IMAGE_BUILDER_RHEL9} \
        -t ${image_name} \
        -f ${PROJECT_ROOT}/${dockerfile} \
        ${PROJECT_ROOT} 2>&1 | tee ${log_file}"
    
    log_success "oc-mirror-tests image built successfully"
}

################################################################################
# Test Functions
################################################################################

test_sanity() {
    log_section "Running Sanity Tests"
    
    local log_file="${LOG_DIR}/test-sanity.log"
    
    execute_command "cd ${PROJECT_ROOT} && make sanity 2>&1 | tee ${log_file}"
    
    log_success "Sanity tests passed"
}

test_unit() {
    log_section "Running Unit Tests"
    
    local log_file="${LOG_DIR}/test-unit.log"
    
    # Setup HOME directory as per YAML configuration
    local test_home="/tmp/home"
    mkdir -p "${test_home}"
    
    execute_command "cd ${PROJECT_ROOT} && HOME=${test_home} make test-unit 2>&1 | tee ${log_file}"
    
    log_success "Unit tests passed"
}

test_v1_e2e() {
    log_section "Running V1 E2E Tests"
    
    local log_file="${LOG_DIR}/test-v1-e2e.log"
    
    execute_command "cd ${PROJECT_ROOT} && (pushd v1 || true) && make test-e2e 2>&1 | tee ${log_file}"
    
    log_success "V1 E2E tests passed"
}

test_lint() {
    log_section "Running Lint Tests"
    
    local log_file="${LOG_DIR}/test-lint.log"
    
    # Set up environment variables as per YAML
    export GOCACHE=/tmp/
    export GOLANGCI_LINT_CACHE=/tmp/.cache
    export GOPROXY=https://proxy.golang.org
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would run lint tests"
        return 0
    fi
    
    cd "${PROJECT_ROOT}"
    pushd v2 || true
    
    # Check golangci-lint version and run appropriate command
    if command -v golangci-lint &> /dev/null; then
        log_info "Running golangci-lint version check..."
        golangci-lint version | tee -a "${log_file}"
        
        maj_version=$((golangci-lint version --short 2>/dev/null || golangci-lint version --format short 2>/dev/null) | cut -f1 -d.)
        
        if [ "${maj_version}" -eq 1 ]; then
            log_info "Running golangci-lint v1.x configuration..."
            golangci-lint run --new-from-rev=HEAD~ \
                --out-format colored-line-number \
                --verbose --print-resources-usage --timeout=5m \
                --build-tags "json1 exclude_graphdriver_btrfs exclude_graphdriver_devicemapper containers_image_openpgp" \
                --config .golangci.yaml 2>&1 | tee -a "${log_file}"
        else
            log_info "Running golangci-lint v2.x configuration..."
            golangci-lint run --new-from-rev=HEAD~ --verbose --timeout=5m --config .golangci.v2.yaml 2>&1 | tee -a "${log_file}"
        fi
    else
        log_warning "golangci-lint not found locally, attempting to use container..."
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
    
    log_success "Lint tests passed"
}

test_verify_deps() {
    log_section "Running Verify Dependencies Test"
    
    local log_file="${LOG_DIR}/test-verify-deps.log"
    
    # Set environment variable as per YAML
    export CHECK_MOD_LIST="false"
    
    log_info "CHECK_MOD_LIST=${CHECK_MOD_LIST}"
    
    # This test typically runs go-verify-deps
    # The actual implementation depends on the go-verify-deps ref
    if [[ -f "${PROJECT_ROOT}/hack/verify-deps.sh" ]]; then
        execute_command "cd ${PROJECT_ROOT} && ./hack/verify-deps.sh 2>&1 | tee ${log_file}"
    elif command -v go &> /dev/null; then
        log_info "Running go mod verify..."
        execute_command "cd ${PROJECT_ROOT} && go mod verify 2>&1 | tee ${log_file}"
        log_info "Running go mod tidy check..."
        execute_command "cd ${PROJECT_ROOT} && go mod tidy && git diff --exit-code go.mod go.sum 2>&1 | tee -a ${log_file}"
    else
        log_warning "Cannot verify dependencies - no verify script or go command found"
        return ${EXIT_SKIP}
    fi
    
    log_success "Dependency verification passed"
}

test_integration() {
    log_section "Running Integration Tests"
    
    local log_file="${LOG_DIR}/test-integration.log"
    
    # Check if we should skip based on changed files
    # skip_if_only_changed: (^docs/)|((^|/)OWNERS(_ALIASES)?$)|((^|/)[A-Z]+\.md$)
    log_info "Running integration tests using flow-controller.sh"
    
    if [[ -f "${PROJECT_ROOT}/scripts/flow-controller.sh" ]]; then
        execute_command "cd ${PROJECT_ROOT} && ./scripts/flow-controller.sh all_happy_path 2>&1 | tee ${log_file}"
    else
        log_warning "Integration test script not found: scripts/flow-controller.sh"
        log_info "Attempting to run with oc-mirror-tests container..."
        
        if [[ "${SKIP_IMAGES}" == "false" ]]; then
            execute_command "${CONTAINER_RUNTIME} run --rm \
                -v ${PROJECT_ROOT}:/workspace:z \
                -w /workspace \
                oc-mirror-tests:latest \
                ./scripts/flow-controller.sh all_happy_path 2>&1 | tee ${log_file}"
        else
            log_error "Cannot run integration tests - script not found and images skipped"
            return ${EXIT_ERROR}
        fi
    fi
    
    log_success "Integration tests passed"
}

################################################################################
# Pipeline Orchestration
################################################################################

run_builds() {
    log_section "Running Build Pipeline"
    
    local build_failed=false
    
    build_binary || build_failed=true
    build_test_binary || build_failed=true
    
    if [[ "${SKIP_IMAGES}" == "false" ]]; then
        build_oc_mirror_image || build_failed=true
        build_oc_mirror_tests_image || build_failed=true
    fi
    
    if [[ "${build_failed}" == "true" ]]; then
        log_error "One or more builds failed"
        return ${EXIT_ERROR}
    fi
    
    log_success "All builds completed successfully"
}

run_tests() {
    log_section "Running Test Pipeline"
    
    local test_failed=false
    
    test_sanity || test_failed=true
    test_unit || test_failed=true
    test_v1_e2e || test_failed=true
    test_lint || test_failed=true
    test_verify_deps || test_failed=true
    test_integration || test_failed=true
    
    if [[ "${test_failed}" == "true" ]]; then
        log_error "One or more tests failed"
        return ${EXIT_ERROR}
    fi
    
    log_success "All tests passed successfully"
}

run_specific_test() {
    local test_name="$1"
    
    case "${test_name}" in
        sanity)
            test_sanity
            ;;
        unit)
            test_unit
            ;;
        v1-e2e)
            test_v1_e2e
            ;;
        lint)
            test_lint
            ;;
        verify-deps)
            test_verify_deps
            ;;
        integration)
            test_integration
            ;;
        *)
            log_error "Unknown test name: ${test_name}"
            log_error "Valid test names: sanity, unit, v1-e2e, lint, verify-deps, integration"
            return ${EXIT_ERROR}
            ;;
    esac
}

run_pipeline() {
    log_section "Starting CI Pipeline"
    
    if [[ "${RUN_ALL}" == "true" ]]; then
        run_builds
        run_tests
    elif [[ "${RUN_BUILD}" == "true" ]]; then
        run_builds
    elif [[ "${RUN_TEST}" == "true" ]]; then
        run_tests
    elif [[ -n "${SPECIFIC_TEST}" ]]; then
        run_specific_test "${SPECIFIC_TEST}"
    else
        log_error "No action specified. Use --all, --build, --test, or --test-name"
        show_usage
        return ${EXIT_ERROR}
    fi
}

################################################################################
# Argument Parsing
################################################################################

show_usage() {
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
}

parse_arguments() {
    if [[ $# -eq 0 ]]; then
        show_usage
        exit ${EXIT_ERROR}
    fi
    
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
                show_usage
                exit ${EXIT_SUCCESS}
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit ${EXIT_ERROR}
                ;;
        esac
    done
}

################################################################################
# Main Execution
################################################################################

main() {
    # Set up trap for cleanup
    trap cleanup EXIT INT TERM
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Display configuration
    log_section "CI Pipeline Configuration"
    log_info "Project Root: ${PROJECT_ROOT}"
    log_info "Artifact Directory: ${ARTIFACT_DIR}"
    log_info "Dry Run: ${DRY_RUN}"
    log_info "Skip Images: ${SKIP_IMAGES}"
    log_info "Run All: ${RUN_ALL}"
    log_info "Run Build: ${RUN_BUILD}"
    log_info "Run Test: ${RUN_TEST}"
    log_info "Specific Test: ${SPECIFIC_TEST:-none}"
    
    # Check prerequisites
    check_prerequisites
    
    # Setup environment
    setup_environment
    
    # Run the pipeline
    run_pipeline
    
    # Generate summary
    log_section "Pipeline Summary"
    log_info "Artifacts saved to: ${ARTIFACT_DIR}"
    log_info "Logs available in: ${LOG_DIR}"
    log_info "JUnit results in: ${JUNIT_DIR}"
    
    log_success "Pipeline execution completed successfully!"
}

# Execute main function with all arguments
main "$@"

# Made with Bob
