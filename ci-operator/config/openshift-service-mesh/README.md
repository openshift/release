# OpenShift Service Mesh CI Documentation

This document provides comprehensive documentation for the OpenShift Service Mesh (OSSM) midstream Prow jobs in the release repository. It serves as a guide for maintaining, triggering, and understanding the CI infrastructure that supports the service mesh components.

## Table of Contents

- [Repository Overview](#repository-overview)
- [Job Inventory](#job-inventory)
  - [1. Istio Repository](#1-istio-repository-openshift-service-meshistio)
    - [Periodic Jobs](#periodic-jobs)
    - [Pre-submit Jobs](#pre-submit-jobs)
    - [Operator-based Integration Tests (Sail)](#operator-based-integration-tests-sail)
  - [2. Proxy Repository](#2-proxy-repository)
    - [Pre-submit Jobs](#pre-submit-jobs-1)
    - [Post-submit Jobs](#post-submit-jobs)
  - [3. Sail Operator Repository](#3-sail-operator-repository-openshift-service-meshsail-operator)
    - [Pre-submit Jobs](#pre-submit-jobs-2)
  - [4. Federation Repository](#4-federation-repository-openshift-service-meshfederation)
  - [5. Ztunnel Repository](#5-ztunnel-repository-openshift-service-meshztunnel)
    - [Periodic Jobs](#periodic-jobs-1)
  - [Job Dependencies](#job-dependencies)
    - [Istio Jobs](#istio-jobs)
    - [Proxy Jobs](#proxy-jobs)
    - [Sail Operator Jobs](#sail-operator-jobs)
- [Technical Deep-dive](#technical-deep-dive)
  - [Test Execution Patterns](#test-execution-patterns)
  - [Job-Specific Technical Details](#job-specific-technical-details)
    - [Istio Integration Tests](#istio-integration-tests)
    - [Proxy Unit Tests](#proxy-unit-tests)
    - [Upstream Synchronization](#upstream-synchronization)
  - [Step Registry Components](#step-registry-components)
    - [Core Workflows](#core-workflows)
    - [Utility Steps](#utility-steps)
  - [Release and Branching Strategy](#release-and-branching-strategy)
    - [Version Alignment](#version-alignment)
    - [Variant Configurations](#variant-configurations)
    - [Key Files and Locations](#key-files-and-locations)
- [Usage of the Performance Sail Operator Job](#usage-of-the-performance-sail-operator-job)
  - [Job Configuration](#job-configuration)
  - [Test Chain Steps](#test-chain-steps)
  - [Manual Triggering](#manual-triggering)
  - [Accessing Test Results](#accessing-test-results)
    - [1. Prow Job Artifacts](#1-prow-job-artifacts)
    - [2. Build Logs](#2-build-logs)
    - [3. Internal Performance Dashboard](#3-internal-performance-dashboard)
    - [4. Performance Analysis Bot (Future)](#4-performance-analysis-bot-future)
  - [Performance Metrics](#performance-metrics)
  - [Use Cases](#use-cases)
  - [Troubleshooting](#troubleshooting)
- [Updating Documentation with Claude](#updating-documentation-with-claude)
  - [When to Update](#when-to-update)
  - [How to Update](#how-to-update)
  - [After Updates](#after-updates)
  - [Validation](#validation)

## Repository Overview

The OpenShift Service Mesh project consists of multiple repositories, each with dedicated CI configurations:

- **istio** - Istio jobs for the [openshift-service-mesh/istio](https://github.com/openshift-service-mesh/istio) repository
- **proxy** - Envoy proxy jobs
- **sail-operator** - Sail operator jobs for the [openshift-service-mesh/sail-operator](https://github.com/openshift-service-mesh/sail-operator) repository
- **federation** - Service mesh federation jobs for the [openshift-service-mesh/federation](https://github.com/openshift-service-mesh/federation) repository. Note: we need to check if this can be deprecated.
- **ztunnel** - Ztunnel jobs for the [openshift-service-mesh/ztunnel](https://github.com/openshift-service-mesh/ztunnel) repository

Each repository maintains branch-specific configurations aligned with OpenShift release cycles and service mesh versions.

## Job Inventory
Take into account that after making any changes to the configuration of the CI jobs, ensure to run `make update` or `make jobs` in the root of the repository to regenerate the Prow job definitions.

**Important:**
After doing any update to the CI configuration files, it is crucial to validate to update the information on this document by running a prompt in your claude cli as is described in the section [Updating Documentation with Claude](#updating-documentation-with-claude).

### 1. Istio Repository (`openshift-service-mesh/istio`)

**Configurations files:**
- `openshift-service-mesh-istio-master.yaml`
- `openshift-service-mesh-istio-release-1.24.yaml`
- `openshift-service-mesh-istio-release-1.26.yaml`
- `openshift-service-mesh-istio-release-1.27.yaml`
- `openshift-service-mesh-istio-gie-backport.yaml`

**Job Types:**

#### Periodic Jobs
- **`sync-upstream-istio-master`** (cron: 00 05 * * 1-5)
  - Automatically merges upstream Istio changes to master branch
  - Uses automator tool from maistra/test-infra
  - Requires GitHub token for API access

#### Pre-submit Jobs
- **`lint`** - Code quality checks and linting
- **`gencheck`** - Generated code verification
- **`unit`** - Unit test execution
- **Integration test suites:**
These jobs run Istio integration upstream tests on OpenShift clusters using specific configurations optimized for OpenShift.
  - `istio-integration-pilot` - Core pilot functionality tests (traffic management, service discovery)
  - `istio-integration-telemetry` - Telemetry and observability tests (metrics, tracing, logging)
  - `istio-integration-security` - Security and mTLS tests (authorization policies, certificates)
  - `istio-integration-ambient` - Ambient mesh mode tests (ztunnel, waypoint proxies)
  - `istio-integration-helm` - Helm installation tests (installation, upgrades)

#### Operator-based Integration Tests (Sail)
These jobs run the same tests as the Istio integration tests using the upstream framework but use the Sail Operator as the control plane installer.
- `istio-integration-sail-pilot` - Pilot tests using Sail operator
- `istio-integration-sail-telemetry` - Telemetry tests using Sail operator
- `istio-integration-sail-security` - Security tests using Sail operator
- `istio-integration-sail-ambient` - Ambient tests using Sail operator

### 2. Proxy Repository

**Configurations files:**
- `openshift-service-mesh-proxy-release-1.24.yaml`
- `openshift-service-mesh-proxy-release-1.26.yaml`
- `openshift-service-mesh-proxy-release-1.27.yaml`

**Job Types:**

#### Pre-submit Jobs
- **`unit`** - Unit test suite for x86_64 architecture
- **`unit-arm`** - Unit test suite for ARM64 architecture
- **`envoy`** (optional) - Extended Envoy-specific tests

#### Post-submit Jobs
- **`copy-artifacts-gcs`** - Uploads build artifacts to Google Cloud Storage
- **`copy-artifacts-gcs-arm`** - Uploads ARM64 build artifacts
- **`update-istio`** - Automatically updates Istio repository with new proxy builds

Note: The Proxy jobs require specific configurations for resource allocation and architecture targeting, for more information check [#job-dependencies](#job-dependencies).

### 3. Sail Operator Repository (`openshift-service-mesh/sail-operator`)

**Configurations:**
- `openshift-service-mesh-sail-operator-main__ocp-4.20.yaml`
- `openshift-service-mesh-sail-operator-main__ocp-4.21.yaml`
- Multiple release-specific configurations (3.0, 3.1, 3.2)
- LP-Interop configurations for layered product testing

**Job Types:**

#### Pre-submit Jobs
- **`e2e-ocp`** - End-to-end operator testing on OpenShift

### 4. Federation Repository (`openshift-service-mesh/federation`)

**Configuration:**
- `openshift-service-mesh-federation-master.yaml`

**Job Types:**
- **`e2e-integration`** - Integration testing for federation features

### 5. Ztunnel Repository (`openshift-service-mesh/ztunnel`)

**Configuration:**
- `openshift-service-mesh-ztunnel-release-1.24.yaml`

**Job Types:**

#### Periodic Jobs
- **`sync-upstream-ztunnel-1.24`** (cron: 00 05 * * 1-5)
  - Syncs upstream ztunnel changes for ambient mesh

### Job Dependencies

#### Istio Jobs
- Integration tests depend on `servicemesh-istio-e2e-hypershift` workflow
- Requires AWS cluster profile (`ossm-aws`)
- Uses `maistra-builder` container images
- Reports results to ReportPortal when `REPORT_TO_REPORT_PORTAL=true`

#### Proxy Jobs
- Unit tests use specialized workflows (`servicemesh-proxy-e2e-aws`, `servicemesh-envoy-e2e-aws`)
- ARM64 tests require `m8gd.8xlarge` node type
- GCS artifact upload requires service account credentials

#### Sail Operator Jobs
- E2E tests depend on `servicemesh-sail-operator-e2e-ocp` step
- Uses `ossm-aws` cluster profile
- Requires `maistra-builder` image
- Reports results to ReportPortal when `REPORT_TO_REPORT_PORTAL=true`

## Technical Deep-dive

### Test Execution Patterns
1. **Source Copy**: Copy source code to test pod via `oc cp`
2. **Kubeconfig Copy**: Copy cluster credentials to test pod
3. **Remote Execution**: Execute tests via `oc rsh` in the test pod
4. **Artifact Collection**: Copy test results back via `oc cp`
5. **Result Reporting**: Send results to ReportPortal if enabled

### Job-Specific Technical Details

#### Istio Integration Tests

**Test Execution Script**: `prow/integ-suite-ocp.sh`

**Test Suites:**
- **pilot** - Core traffic management and service discovery
- **telemetry** - Metrics, tracing, and logging functionality
- **security** - mTLS, authorization policies, certificates
- **ambient** - Ambient mesh mode with ztunnel
- **helm** - Installation and upgrade testing

**Environment Variables:**
```yaml
INSTALLATION_METHOD: helm|sail    # Report Portal attribute
CONTROL_PLANE_SOURCE: sail        # Report Portal attribute
INSTALL_SAIL_OPERATOR: true       # Deploy operator
AMBIENT: true                     # Enable ambient mode
```

**Known Test Exclusions:**
Tests are selectively skipped using pattern exclusion:
- Gateway conformance tests (OCP compatibility issues)
- CNI version skew tests (environment limitations)
- Experimental Gateway API features (CRD availability)

#### Proxy Unit Tests

**Test Script**: `./ossm/ci/pre-submit.sh`

**Resource Configuration:**
```yaml
CI: "true"
LOCAL_CPU_RESOURCES: "30"
LOCAL_RAM_RESOURCES: "61440"
LOCAL_JOBS: "30"
COMPUTE_NODE_TYPE: m5d.8xlarge  # x86_64
COMPUTE_NODE_TYPE: m8gd.8xlarge # ARM64
```

**Timeout**: 8 hours (proxy compilation is resource-intensive)

#### Upstream Synchronization

**Tool**: `maistra/test-infra` automator scripts

**Process:**
1. Clone test-infra repository
2. Execute `automator-main.sh` with repository-specific parameters
3. Create automated pull requests with upstream changes
4. Auto-merge via `tide/merge-method-merge` label

**Repositories Synced:**
- `istio/istio` → `openshift-service-mesh/istio`
- `istio/ztunnel` → `openshift-service-mesh/ztunnel`
- `istio-ecosystem/sail-operator` → `openshift-service-mesh/sail-operator`

### Step Registry Components

The service mesh jobs leverage several step registry components:

#### Core Workflows
- **`servicemesh-istio-e2e-hypershift`**: HyperShift cluster provisioning for Istio tests
- **`servicemesh-istio-e2e-profile`**: Standard cluster provisioning for Istio tests
- **`servicemesh-proxy-e2e-aws`**: Proxy-specific AWS cluster setup
- **`servicemesh-envoy-e2e-aws`**: Envoy-specific AWS cluster setup

#### Utility Steps
- **`servicemesh-sail-operator-copy-src`**: Source code copying for Sail operator
- **`servicemesh-sail-operator-e2e-ocp`**: Sail operator E2E test execution
- **`servicemesh-send-results-to-reportportal`**: Test result reporting

### Release and Branching Strategy

#### Version Alignment
- Service mesh versions align with Istio upstream releases (1.24, 1.26, 1.27)
- OpenShift versions supported per release (4.20, 4.21, etc.)
- Sail operator maintains independent versioning related to OSSM versions (3.0, 3.1, 3.2)

#### Variant Configurations
- LP-Interop variants for layered product testing
- OCP-specific variants with version targeting
- Architecture-specific configurations (x86_64, ARM64)

#### Key Files and Locations

**Configuration Files**: `ci-operator/config/openshift-service-mesh/`
**Generated Jobs**: `ci-operator/jobs/openshift-service-mesh/`
**Step Registry**: `ci-operator/step-registry/servicemesh/`

## Usage of the Performance Sail Operator Job

The performance job (`istio-pr-perfscale`) is designed to measure service mesh performance in both ambient and sidecar modes. This job helps detect performance regressions between versions and provides baseline metrics for comparison.

### Job Configuration

The performance job has specific cluster and resource requirements:

```yaml
- always_run: false
  as: istio-pr-perfscale
  optional: true
  steps:
    cluster_profile: ossm-aws
    env:
      BASE_DOMAIN: servicemesh.devcluster.openshift.com
      COMPUTE_NODE_REPLICAS: "5"
      COMPUTE_NODE_TYPE: m6i.2xlarge
      CONTROL_PLANE_INSTANCE_TYPE: m6i.xlarge
      OPENSHIFT_INFRA_NODE_INSTANCE_TYPE: c6i.4xlarge
      SAIL_OPERATOR_CHANNEL: 1.28-nightly
      SET_ENV_BY_PLATFORM: custom
      ZONES_COUNT: "1"
    test:
    - chain: servicemesh-istio-perfscale
    workflow: openshift-qe-installer-aws
  timeout: 5h0m0s
```

### Test Chain Steps

The `servicemesh-istio-perfscale` chain performs the following tests:

1. **Ambient Mode Testing**:
   - Deploy control plane in ambient mode (`servicemesh-sail-operator-deploy-controlplane-ambient`)
   - Configure ambient environment (`openshift-qe-servicemesh-ambient-configure`)
   - Run ambient ingress performance tests (`openshift-qe-servicemesh-ambient-ingress-perf`)
   - Run ambient network performance tests (`openshift-qe-servicemesh-ambient-network-perf`)

2. **Sidecar Mode Testing**:
   - Undeploy ambient control plane (`servicemesh-sail-operator-undeploy-controlplane`)
   - Deploy control plane in sidecar mode (`servicemesh-sail-operator-deploy-controlplane-sidecar`)
   - Configure sidecar environment (`openshift-qe-servicemesh-sidecar-configure`)
   - Run sidecar ingress performance tests (`openshift-qe-servicemesh-sidecar-ingress-perf`)
   - Run sidecar network performance tests (`openshift-qe-servicemesh-sidecar-network-perf`)

### Manual Triggering

The Sail Operator performance job can only be triggered manually from a PR in the Sail Operator repository. This job is not configured to run automatically on any event.

**To trigger the job:**
1. Create or use an existing PR in [openshift-service-mesh/sail-operator](https://github.com/openshift-service-mesh/sail-operator)
2. Add a comment with the text: `/test ocp-4.20-istio-pr-perfscale`

Example PR: [openshift-service-mesh/sail-operator #633](https://github.com/openshift-service-mesh/sail-operator/pull/633)

**Important notes:**
- Job duration: ~4 hours (timeout: 5 hours)
- The job requires significant compute resources (5 m6i.2xlarge nodes)
- Performance configuration may need manual updates depending on testing requirements

### Accessing Test Results

Performance test results are available in multiple formats and locations:

#### 1. Prow Job Artifacts
After job completion, navigate to the Prow run URL and access artifacts:
```
https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift_release/<job-id>/artifacts/istio-pr-perfscale/
```

Key directories:
- `ingress/` - Contains ingress performance test results
- `network/` - Contains network performance test results

#### 2. Build Logs
Raw performance data is available in build logs:
```
https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift-service-mesh-<module>-<job-id>/build-log.txt
```

Look for lines containing performance metrics:
```
time="2025-12-05 18:10:01" level=info msg="http: Rps=5001 avgLatency=2ms P95Latency=2ms" file="exec.go:149"
```

#### 3. Internal Performance Dashboard
**Note: Requires VPN access and Red Hat internal credentials**

- **Grafana Dashboard**: `http://ocp-intlab-grafana.rdu2.scalelab.redhat.com:3000/`
  - Credentials: `viewer/viewer` (read-only access)
  - Search for service mesh performance metrics by UUID

#### 4. Performance Analysis Bot (Future)
An internal Slack bot for automated performance regression detection is planned:
```
@PerfScale Jedi analyze pr: https://github.com/openshift-service-mesh/sail-operator/pull/XXX, compare with 4.21
```

**Current status**: In development, expected implementation timeline depends on team capacity.

### Performance Metrics

The performance tests measure:

**Ingress Performance**:
- Requests per second (RPS)
- Average latency
- P95 latency percentile
- Resource utilization

**Network Performance**:
- Network throughput
- Connection establishment time
- Proxy overhead measurements

**Test Configuration**:
Each test run generates a UUID that can be used to correlate results across different systems and dashboards.

### Use Cases

This job is primarily used for:
1. **Version Bump Testing**: Detect regressions when updating service mesh versions
2. **Performance Baseline**: Establish performance baselines for new releases
3. **Comparative Analysis**: Compare OpenShift service mesh performance with upstream benchmarks
4. **Resource Planning**: Understand resource requirements for different deployment modes

### Troubleshooting

**Common Issues**:
- Job timeout: Consider increasing timeout if tests consistently run close to 5 hours
- Resource allocation: Verify AWS cluster has sufficient capacity for requested instance types
- Results access: Ensure VPN connection and proper credentials for internal dashboards

**Getting Help**:
- Performance-related questions: Contact the PerfScale team via internal Slack channels
- Job configuration issues: Contact the OpenShift Service Mesh team

## Updating Documentation with Claude

This documentation should be updated whenever changes are made to the OpenShift Service Mesh CI configuration. Use Claude Code to automatically regenerate and update this README file.

### When to Update

Update this documentation when:
- New job configurations are added or removed
- Job parameters or environment variables change
- New repositories or branches are added to the service mesh project
- Step registry components are modified
- Performance job configurations change
- New workflow patterns are introduced

### How to Update

**Prerequisites:**
- Ensure you have Claude Code installed and configured
- Navigate to the root of the `release` repository

**Prompt to use:**
```
I need you to analyze and update the documentation file ci-operator/config/openshift-service-mesh/README.md that describes the OpenShift Service Mesh midstream Prow jobs in the release repository.

Please review all configuration files in the ci-operator/config/openshift-service-mesh/ directory and any related step registry components to identify changes that need to be reflected in the documentation.

The updated documentation should include:

1. **Repository Overview**: Current list of service mesh repositories with accurate descriptions and purposes
2. **Job Inventory**: Complete inventory of all Prow jobs categorized by:
   - Repository (istio, proxy, sail-operator, federation, ztunnel)
   - Job type (periodic, pre-submit, post-submit)
   - Branch/version specific configurations
3. **Job Configurations**: Accurate job parameters, environment variables, and resource requirements
4. **Usage Instructions**:
   - How to trigger jobs manually
   - Special triggering requirements (like performance jobs)
   - Command examples
5. **Technical Details**:
   - Test execution patterns
   - Step registry component usage
   - Workflow dependencies
   - Environment setup requirements
6. **Performance Jobs**: Complete section on performance testing including:
   - Job configuration details
   - How to access results
   - Performance metrics measured
   - Troubleshooting guidance
7. **Maintenance Information**:
   - Release and branching strategies
   - Key file locations
   - Update procedures

**Important requirements:**
- Preserve the existing structure and formatting
- Include accurate file paths and URLs
- Verify all job names and configuration details against current files
- Update any outdated information
- Ensure all examples and commands are current
- Keep technical deep-dive sections comprehensive

Please analyze the current CI configurations and update the documentation to reflect the current state accurately.
```

### After Updates

After updating the documentation:

1. **Review Changes**: Carefully review the generated updates to ensure accuracy
2. **Check Examples**: Verify that any examples or procedures work as documented
3. **Update Version**: Consider updating any version references if applicable
4. **Commit Changes**: Commit the updated documentation with a descriptive message:
   ```bash
   git add ci-operator/config/openshift-service-mesh/README.md
   git commit -m "docs: Update OpenShift Service Mesh CI documentation

   - Updated job inventory to reflect current configurations
   - Refreshed technical details and usage instructions
   - Verified all examples and procedures"
   ```
