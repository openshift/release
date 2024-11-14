The intention of creating the Prow job naming regulation is to make sure we name and manage our jobs consistently. We have tools and automation services like ReportPortal, Sippy and build-on-demand that require us to create jobs following certain naming rules, having consistent naming ensures these automation functions seamlessly, failing to do so would make some of these integrated services fail to function properly.

# Job Configuration Location
In https://github.com/openshift/release.git under the *ci-operator/config/openshift/openshift-tests-private* directory

## Configuration File Types
There are two types of Prow configuration files under *openshift-tests-private*:
- Infrastructure file
  - This kind of file do not define test cases
  - These files are used to setup test environment, like creating images in image stream
  - There are two types of infrastructure files:
    - Pre-merge files: these files will be triggered when image file changes are submitted, it will generate new images or update existing images in image stream against the change in image file. Pre-merge file name like: *openshift-openshift-tests-private-release-4.15.yaml*
    - Image files: these files define images,and export images into image stream. Image file name like: *openshift-openshift-tests-private-release-4.15__images.yaml*
- Test case config file
  - We define test cases in these kind of files.
  - There are two kind of test files: E2E tests and Upgrade Tests.
  - Tests will be triggered periodically against its settings.

## E2E Test File Naming
All E2E jobs under the job configuration location should have a consistent file naming rule as openshift-openshift-tests-private-release-VERSION__ARCH-STREAM.yaml, we will break down this to detail:
- VERSION: the OCP version, namely 4.14, 4.15, 4.16...
- ARCH: architecture of the OCP build, valid values are: amd64, arm64, multi, ppc64le
- STREAM: the release stream, valid values are: nightly, stable

Example: **openshift-openshift-tests-private-release-4.12__arm64-nightly.yaml**: a 4.12 job that runs tests for ocp 4.12 nightly in arm64 architecture.

## Upgrade Test File Naming
Upgrade jobs have same location as E2E files but different file naming.
Upgrade job file naming rule is:
openshift-openshift-tests-private-release-VERSION__ARCH-TargetStream-TargetVersion-upgrade-from-InitStream-InitVersion

For example: **openshift-openshift-tests-private-release-4.15__multi-nightly-4.15-upgrade-from-stable-4.14.yaml**

## Job Naming
All jobs under the job configuration location should have a consistent file naming rule as PLATFORM-INSTALLMETHOD-CONFIG1-CONFIG2-CONFIG*-FREQUENCY

- PLATFORM: the platform to run e2e, valid values are: alicloud, aws, azure, baremetal, gcp, ibmcloud, nutanix, openstack, vsphere
- INSTALLMETHOD: valid values are: ipi, upi
- CONFIG1, CONFIG2, CONFIG*: represent a cluster configuration, like ovn, ipsec, fips, proxy, cco etc. You could add multiple configs following the same convention.
- FREQUENCY: how often is the job executed, see more details in job frequency

Example: **aws-ipi-ovn-ipsec-f1**: runs e2e tests on profile aws ipi with ovn, ipsec, and test frequency is f1 (daily)


## Job Frequency
Job frequency is defined by cron according to the test requirements
- f1: daily
- f2: every 2 days
- f3: every 3 days
- f4: every 4 days
- f5: every 5 days
- ...
- f999: disable the job temporarily

~~~
NOTE: We can use below script to generate cron settings against the frequency:
      ci-operator/config/openshift/openshift-tests-private/tools/generate-cron-entry.sh
~~~

# Installer (base_images)
Available installers can be found in: ci-operator/config/openshift/installer
Examples:
  upi-installer:
    name: "4.14"
    namespace: ocp
    tag: upi-installer

  openstack-installer:
    name: "4.14"
    namespace: ocp
    tag: openstack-installer

# releases:
The releases configuration option allows specification of a version of OpenShift that a component will be tested on.
For details, please refer [Testing With an Ephemeral OpenShift Release](https://docs.ci.openshift.org/docs/architecture/ci-operator/#testing-with-an-ephemeral-openshift-release)

## For E2E test
latest: latest release describes the version that will be installed before tests are run.

## For Upgrade Test
initial: initial release describes the version of OpenShift which is initially installed, after which an upgrade is executed to the latest release, after which tests are run.
latest: upgrade to version.

## For non-amd64 tests, we have to keep latest and target settings as test framework need them.

## Suggest to use fast channel as the init installed payload for upgrade tests

## Examples
###  Below is the script used to get a stable/ec build
Get payload from release page(a release page like https://amd64.ocp.releases.ci.openshift.org/)
```
releases:
  latest: # User defined name, can be accessed in all test steps
    # Below is Prow definde structure
    prerelease: # references a version known to a release controller (release page)
      architecture: arm64   # amd64, arm64, multi, ppc64le
      product: ocp
      version_bounds:   # find latest version >= lower and < upper
        lower: 4.14.0-0
        upper: 4.15.0-0
```
get payload from channel
```
releases:
  arm64-latest:
    # Below is Prow definde structure
    release:    # references a version from Red Hat's Cincinnati update service https://api.openshift.com/api/upgrades_info/v1/graph
      architecture: arm64
      channel: fast # candidate, fast, stable, eus
      version: "4.12"
```
### Below is the script used to get a nightly/ci build
```
releases:
  previous: # anything is accepted here, it can be override in the tests
    # Below is Prow definde structure
    candidate:
      product: ocp
      architecture: amd64
      stream: nightly     # specifies a candidate release stream
      version: "4.5"
      relative: 1         # resolves to the Nth latest payload in this stream
```


# Trigger a new test for an existing periodic job in Prow
Navigate to the app.ci console URL (For URL, search 'prow' in BitWarden). After logging in (via SSO) to this cluster using the console, use the link in the top right “Copy login command” to get your token.
Run the specific periodic job you want using REST API.
```
TOKEN='sha256~the_token_you_get_from_above'
GANGWAY_API='https://gangway***.com' # For API URL, search 'prow' in BitWarden
JOB_NAME='replace-me-eg-periodic-ci-openshift-openshift-tests-private-release-4.14-amd64-nightly-gcp-ipi-sdn-migration-ovn-f7'
$ curl -X POST -d '{"job_execution_type": "1"}' -H "Authorization: Bearer ${TOKEN}" "${GANGWAY_API}/v1/executions/${JOB_NAME}"
{
 "id": "d7c56195-428f-4217-aab0-6f95b2f2e763",
 "job_name": "periodic-ci-openshift-openshift-tests-private-release-4.14-amd64-nightly-gcp-ipi-sdn-migration-ovn-f7",
 "job_type": "PERIODIC",
 "job_status": "TRIGGERED",
 "gcs_path": ""
}
```
You should be able to find the triggered job in QE PRIVATE DECK (search 'prow' in BitWarden for the URL) via job name.

If you would like to run the tests on a specific payload,
```
# for E2E testing,
$ curl -X POST -d '{"job_execution_type": "1", "pod_spec_options": { "envs":  {"RELEASE_IMAGE_LATEST": "quay.io/openshift-release-dev/ocp-release:4.14.0-ec.1-x86_64"} } }' -H "Authorization: Bearer ${TOKEN}" "${GANGWAY_API}/v1/executions/${JOB_NAME}"
# for upgrade testing,
JOB_NAME='replace-me-eg-periodic-ci-openshift-openshift-tests-private-release-4.14-amd64-nightly-4.14-upgrade-from-stable-4.13-aws-ipi-network-mtu-localzone-f14'
$ curl -X POST -d '{"job_execution_type": "1", "pod_spec_options": { "envs":  {"RELEASE_IMAGE_LATEST": "quay.io/openshift-release-dev/ocp-release:4.13.2-x86_64", "RELEASE_IMAGE_TARGET": "quay.io/openshift-release-dev/ocp-release:4.14.0-ec.1-x86_64"} } }' -H "Authorization: Bearer ${TOKEN}" "${GANGWAY_API}/v1/executions/${JOB_NAME}"
```
You can use `-v` option for curl to see detailed information about the request as well as error message.
