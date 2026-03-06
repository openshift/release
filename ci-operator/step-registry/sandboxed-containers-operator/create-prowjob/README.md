# Sandboxed Containers Operator - Prowjob Configuration Generator

`sandboxed-containers-operator-create-prowjob-commands.sh` generates prowjob configuration files for the Sandboxed Containers Operator with validation and error handling.  The existing files should not be edited directly.  `sandboxed-containers-operator-create-prowjob-commands.sh` can also be used to run prowjobs with Gangway, like Konflux

## Overview

The `sandboxed-containers-operator-create-prowjob-commands.sh` script creates prowjob configuration files.  These prowjobs contain variations of provider/workload combinations.  We will start with [Creating Prowjobs](#creating-prowjobs) and [Running Prowjobs](#running-prowjobs).  More detail starts in [General Usage](#general-usage).

## Creating Prowjobs
`sandboxed-containers-operator-create-prowjob-commands.sh update_templates` regenerates all exising prowjobs with the script defaults, these jobs are used directly by Konflux.  It is preferred to make all changes in the script and not make changes in existing prowjobs.  Also see [Update Templates](#update-templates)

`sandboxed-containers-operator-create-prowjob-commands.sh create` creates a yaml file in the current directory. Environment variables alter the yaml output. `create` is used by `update_templates` also.

## Running Prowjobs
### Konflux and Gangway
You cannot login to Gangway created clusters by design.  They are useful for rerunning tests launched from Konflux without creating a new build.  ex: infrastructure issues prevent the test from starting

Either use an existing YAMLFILE or `create` a new YAMLFILE in the current directory.  From this YAMLFILE, we can `run` to create a cluster on PROVIDER and run the WORKLOAD tests using the Gangway API.  You will need a Prow API token as explained in the [Gangway](#gangway) section
```bash
sandboxed-containers-operator-create-prowjob-commands.sh run <YAMLFILE> <PROVIDER-ipi-WORKLOAD>
```
 Konflux modifies a copy of the template files and uses Gangway to launch tests.

### Interactive
1. Create a branch `git checkout -b BRANCH` in the repo.
2. `create` the YAMLFILE in the current directory with your ENV changes.  We want the cluster to stay around for 6 hours after the tests finish.
   ```bash
    SLEEP_DURATION=6h OCP_VERSION=4.21 TEST_RELEASE_TYPE=Pre-GA `sandboxed-containers-operator-create-prowjob-commands.sh create`
    ```
    `sandboxed-containers-operator-create-prowjob-commands.sh create` output has directions to mv the file, add to git and run a series of make commands.  Don't follow them yet
3. You need modify the YAMLFILE to allow interaction
   ```bash
   sed -ie 's/restrict_network_access: false/restrict_network_access: true/ ' YAMLFILE
   ```
**NOTE: this will prevent the RPM upload if you need to install one!**  You will need to upload the RPM to the nodes and install them after the kataconfig is installed.  It will also make the automated tests invalid

4. Now follow the directions to mv the file, add to git, run make commands
5. `git status -uno` and git add any changed files
6. `git commit -m '[DEBUG] [DO NOT MERGE]'`
7. `git push --set-upstream origin BRANCH`
8. Go to the PR and interact with it

#### Interactive in the PR
The openshift-ci-robot will list a number of test names you can can with `/pj-rehearse`

If I created a prowjob as above, I will have a series like
```bash
periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-candidateOCP_VERSION-PROVIDER-ipi-WORKLOAD
```
Launch with
```bash
/pj-rehearse periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-candidate421-aws-ipi-peerpods
```
This will launch the tests that konflux's run does.  But you can get interactive access to the cluster.

#### Interactive Cluster Access
In the PR, you will see a _pending check_ that looks like `ci/rehearse/periodic-ci-openshift-sandboxed-containers..` that is a URL to the **Spyglass** page for the prowjob.  This page has all the logs and artifacts for your prowjob.  In the **Build Log** section, you will see _Using namespace_ followed by a URL.  This is the undercluster that is building your cluster.  It will log you into the undercluster.  Under **Inventory** you will see a pod for every step in the prowjob that has finished and the current running one.  While it is running, the `PROVIDER-ipi-WORKLOAD-openshift-extended-test` pod will show the output of the test in its log.

Further under **Inventory** are secrets.  The `PROVIDER-ipi-WORKLOAD` secret will eventually have the `kubeadmin-password` and `kubeconfig` files you can reveal and copy.  This usually happends while the tests are running.

Once you have the credentials you can login to the cluster.  However, you should only observe until the tests finish.  The pod `PROVIDER_ipi-WORKLOAD-cucushift-installer-wait` will appear and stay running for `SLEEP_DURATION` hours.  Then the pod will end and prow will deprovision.  You can login to the pod and terminate the sleep loop early.  You can only make the pod last 12 hours.


## General Usage
### Basic Usage of `sandboxed-containers-operator-create-prowjob-commands.sh`

Ensure you are in the __release__ directory of your fork of the [Prow repo](https://github.com/openshift/release)
The script uses environment variables exclusively for configuration:

```bash
# Generate configuration with defaults
ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh create

# Generate configuration with custom OCP version
OCP_VERSION=4.17 ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh create

# Run jobs from generated YAML file
PROW_API_TOKEN=your_token_here ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh run openshift-sandboxed-containers-operator-devel__downstream-candidate419.yaml

# Run specific job
PROW_API_TOKEN=your_token_here ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh run openshift-sandboxed-containers-operator-devel__downstream-candidate419.yaml azure-ipi-kata
```

### Environment Variables

| Variable                   | Default Value            | Description                                                                 | Validation               |
| -------------------------- | ------------------------ | --------------------------------------------------------------------------- | ------------------------ |
| `OCP_VERSION`              | Files for 4 OCP versions are pregenerated | OpenShift Container Platform version. Supports `X.Y` (latest), `X.Y.Z` (specific), or `X.Y.Z-rc.N`/`X.Y.Z-ec.N` (candidate). | If a specific version doesn't exist, error out.
| `OCP_CHANNEL`              | `fast`                   | OCP release channel. Default is `fast` because it contains all versions that could become `stable`.  Further explanation below | `stable`, `fast`, `candidate`, or `eus` |
| `AWS_REGION_OVERRIDE`      | `us-east-2`              | AWS region for testing                                                      | Any valid AWS region     |
| `CUSTOM_AZURE_REGION`      | `eastus`                 | Azure region for testing                                                    | Any valid Azure region   |
| `OSC_CATALOG_TAG`          | `latest`                 | Defaults to `:latest`. Actual tag resolved at runtime by `env-cm` step. Can override with specific version tag (e.g., `1.11.1-1766149846`) or SHA | repo tag or SHA          |
| `INSTALL_KATA_RPM`         | `true`                   | Whether to install Kata RPM                                                 | `true` or `false`        |
| `KATA_RPM_VERSION`         | `3.17.0-3.rhaos4.19.el9` | Kata RPM version (when `INSTALL_KATA_RPM=true`)                             | RPM version format       |
| `PROW_RUN_TYPE`            | `candidate`              | Prow job run type                                                           | `candidate` or `release` |
| `SLEEP_DURATION`           | `0h`                     | Time to keep cluster alive after tests.  For manual testing.                | 0-12 followed by 'h'     |
| `TEST_RELEASE_TYPE`        | `Pre-GA`                 | Release type for testing                                                    | `Pre-GA` or `GA`         |
| `TEST_TIMEOUT`             | `90`                     | Test timeout in minutes                                                     | Numeric value            |

### Pre-GA vs GA Configuration
<!-- COMMIT Use actual variable names in sections -->

#### Pre-GA (Development) Mode
- Uses `:latest` tag for catalog images by default
  - The `env-cm` step resolves the actual latest tag (X.Y.Z-epoch_time format) at runtime
  - This ensures jobs always test against the most recent build
- Creates `brew-catalog` source with the resolved catalog tag

#### GA (Production) Mode
- Uses `redhat-operators` catalog source with GA images

### OCP Release Channels

The `OCP_CHANNEL` variable determines which OpenShift release channel to use.  Use `candidate` for rc/ec versions

#### Channel Comparison

| Channel | Pre-Release | Use Case |
|---------|-------------|----------|
| `candidate` | Yes (RC/EC) | Pre-release testing |
| `fast`      | No | **Default** - has all versions except `candidate` |
| `stable`    | No | version tested for upgrades |
| `eus`       | No | Long-term support |

### Advanced Configuration Examples

#### Pre-GA Development Testing
```bash
# Test latest development builds
TEST_RELEASE_TYPE=Pre-GA \
PROW_RUN_TYPE=candidate \
OCP_VERSION=4.18 \
ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh create
```

#### GA Production Testing
```bash
# Test production releases
TEST_RELEASE_TYPE=GA \
PROW_RUN_TYPE=release \
OCP_VERSION=4.19 \
ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh create
```

#### Custom Regions and Timeouts
```bash
# Extended testing with custom regions
AWS_REGION_OVERRIDE=us-west-2 \
CUSTOM_AZURE_REGION=westus2 \
SLEEP_DURATION=2h \
TEST_TIMEOUT=120 \
ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh create
```

#### Kata RPM Testing
```bash
# Test without Kata RPM installation
INSTALL_KATA_RPM=false \
ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh create

# Test with specific Kata RPM version
INSTALL_KATA_RPM=true \
KATA_RPM_VERSION=3.18.0-3.rhaos4.20.el9 \
ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh create
```

## Catalog Tag Discovery

### Runtime Tag Resolution

The `create-prowjob` script uses `:latest` as the default tag. The actual latest tag is resolved at **runtime** by the `env-cm` step when the job executes.

### How It Works
<!-- COMMIT remove this section -->
1. **At config generation time**: `CATALOG_SOURCE_IMAGE` is set to `quay.io/redhat-user-workloads/ose-osc-tenant/osc-test-fbc:latest`
2. **At job runtime**: The `env-cm` step checks the tag:
   - If the tag is `:latest`, it queries the Quay API to find the most recent `X.Y.Z-unix_epoch` tag
   - If the tag is anything else (specific version or SHA), it is passed through unchanged
3. **Supported tag formats**:
   - `latest` - resolved to newest `X.Y.Z-unix_epoch` tag at runtime
   - `X.Y.Z-unix_epoch` (e.g., `1.11.1-1766149846`) - passed through unchanged
   - SHA (e.g., `sha256:abc123...` or short SHA) - passed through unchanged
4. **Source**: `quay.io/redhat-user-workloads/ose-osc-tenant/osc-test-fbc`


## Gangway

### Run Command Features

- **Exactly one job**: You must provide the job YAML file and exactly one job name; neither more nor fewer are allowed.
- **Job Name Generation**: Constructs the full job name as `periodic-ci-{org}-{repo}-{branch}-{variant}-{job_name}`.
- **Metadata Extraction**: Extracts organization, repository, branch, and variant from the YAML file's `zz_generated_metadata` section.
- **API Integration**: Uses the Prow/Gangway API to trigger the job.
- **Job Status Monitoring**: Provides job ID and status information.


### Gangway `PROW_API_TOKEN`

To trigger ProwJobs via Gangway, you need a token for authentication. Tokens can be retrieved through the UI of the app.ci cluster at [OpenShift Console](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com).

Tf the app.ci cluster context is already configured:
```bash
oc whoami -t
```

Set `PROW_API_TOKEN` to the token

```bash
export PROW_API_TOKEN=your_token_here
```

For complete information about triggering ProwJobs via REST, including permanent tokens for automation, see the [OpenShift CI documentation](https://docs.ci.openshift.org/docs/how-tos/triggering-prowjobs-via-rest/#obtaining-an-authentication-token).

The `run` command triggers a single ProwJob from a generated YAML configuration file. You must specify exactly one job name (the `as` value from the tests in the YAML, e.g. `azure-ipi-kata`, `aws-ipi-peerpods`). This command requires a valid Prow API token.

### Spyglass
#### Viewing the Run's URL
Go to [Prow configured jobs](https://prow.ci.openshift.org/configured-jobs/)
Scroll down to *sandboxed-containers-operator* and click on it
Search for the prow job you specified (ex aws-ipi-peerpods) and click on _Details_
Click on _History_
You will be taken to a list of the **Build** numbers, etc.  Your job should be at the top.  Clicking on that will show you the Spyglass of your job with the build log, artifacts, etc.
This URL is used by **dig&shift** for reporting and analysis.  It will look something like [this](https://prow.ci.openshift.org/view/gs/test-platform-results/pr-logs/pull/openshift_release/75051/rehearse-75051-periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-candidate421-azure-ipi-kata/2024178159888371712)


## Update Templates

The script generates configuration for 5 test scenarios:

1. **azure-ipi-kata**: Azure kata
2. **azure-ipi-peerpods**: Azure peer-pods
3. **azure-ipi-coco**: Azure coco
4. **aws-ipi-peerpods**: AWS peer-pods
5. **aws-ipi-coco**: AWS coco

Each test includes:
- Appropriate cloud provider configuration
- Catalog source settings based on release type
- Runtime class configuration
- Environment-specific parameters

## Output and Next Steps

### Generated Files
- **File Name**: `openshift-sandboxed-containers-operator-devel__downstream-{PROW_RUN_TYPE}{OCP**_VERSION**}.yaml`
- **Location**: Current directory
- **Backup**: Existing files are backed up with `.backup` extension

### Deployment Process
1. **Review** the generated configuration:
   ```bash
   cat openshift-sandboxed-containers-operator-devel__downstream-candidate4.19.yaml
   ```

2. **Move** to the appropriate directory:
   ```bash
   mv openshift-sandboxed-containers-operator-devel__downstream-candidate4.19.yaml \
      ci-operator/config/openshift/sandboxed-containers-operator/
   ```
_Things will not compile with files in the wrong location_

3. **Generate** CI configuration:
   ```bash
   make ci-operator-config && make registry-metadata && make prow-config && make jobs && make update
   ```

## Validation and Error Handling

The script includes comprehensive validation:

- **Parameter Format**: Validates version formats, boolean values, numeric ranges
- **API Connectivity**: Tests Quay API availability and response validity
- **File Operations**: Checks file creation, YAML syntax (when `yq` available)
- **Configuration Logic**: Ensures consistent catalog source configuration

### Common Error Scenarios
- **Invalid OCP_VERSION**: Must be in X.Y format
- **Invalid SLEEP_DURATION**: Must be 0-12 followed by 'h'
- **API Failures**: Network issues or catalog tag discovery failures
- **File Conflicts**: Existing file backup and overwrite handling

## Troubleshooting

### Catalog Tag Discovery Issues

Tag resolution happens at runtime in the `env-cm` step. To troubleshoot:

```bash
# Test connectivity to Quay API
curl -sf "https://quay.io/api/v1/repository/redhat-user-workloads/ose-osc-tenant/osc-test-fbc/tag/?limit=10&page=1"

# Check for matching tags manually (X.Y.Z-unix_epoch format)
curl -s "https://quay.io/api/v1/repository/redhat-user-workloads/ose-osc-tenant/osc-test-fbc/tag/" | \
  jq -r '.tags[] | select(.name | test("^[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+$")) | "\(.start_ts) \(.name)"' | \
  sort -nr | head -5

# Override with a specific tag if needed
OSC_CATALOG_TAG=1.11.1-1766149846 ./sandboxed-containers-operator-create-prowjob-commands.sh create
```

### YAML Validation
```bash
# Install yq for validation
# On macOS: brew install yq
# On Linux: Download from https://github.com/mikefarah/yq/releases

# Validate generated YAML
yq eval '.' openshift-sandboxed-containers-operator-devel__downstream-candidate4.19.yaml
```

## Dependencies

- **Required**: `curl`, `jq`, `awk`, `sort`, `head`
- **Optional**: `yq` (for YAML syntax validation)
- **Network**: Access to `quay.io` API endpoints
