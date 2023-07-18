The intention of creating the Prow job naming regulation is to make sure we name and manage our jobs consistently. We have tools and automation services like ReportPortal, Sippy and build-on-demand that require us to create jobs following certain naming rules, having consistent naming ensures these automation functions seamlessly, failing to do so would make some of these integrated services fail to function properly.

# Job Configuration Location
In https://github.com/openshift/release.git under the *ci-operator/config/openshift/openshift-tests-private* directory

# File Naming
All E2E jobs under the job configuration location should have a consistent file naming rule as openshift-openshift-tests-private-release-VERSION__ARCH-STREAM.yaml, we will break down this to detail:
- VERSION: the OCP version, namely 4.10, 4.11, 4.12..
- ARCH: architecture of the OCP build, valid values are: amd64, arm64, multi
- STREAM: the release stream, valid values are: nightly, stable

Example: **openshift-openshift-tests-private-release-4.12__arm64-nightly.yaml**: a 4.12 job that runs tests for ocp 4.12 nightly in arm64 architecture.


# Job Naming
All E2E jobs under the job configuration location should have a consistent file naming rule as e2e-PLATFORM-INSTALLMETHOD-CONFIG1-CONFIG2-CONFIG*-PRIORITY-FREQUENCY

- PLATFORM: the platform to run e2e, valid values are: alicloud, aws, azure, baremetal, gcp, ibmcloud, nutanix, openstack, vsphere
- INSTALLMETHOD: valid values are: ipi, upi
- CONFIG1, CONFIG2, CONFIG*: represent a cluster configuration, like ovn, ipsec, fips, proxy, cco etc. You could add multiple configs following the same convention.
- PRIORITY: the priority of this job, valid values are: p1, p2, p3, see more details in google doc "Integration Test Configuration Matrix" for specific versions
- FREQUENCY: how often is the job executed, see more details in job frequency

Example: **e2e-aws-ipi-ovn-ipsec-p1-f1**: runs e2e tests on profile aws ipi with ovn, ipsec as p1, and test frequency is f1 (daily)


# Job Frequency
Job frequency is defined by cron according to the priority of a job (subject to change in different test phase) 
- f1: daily
- f2: every 2 days
- f3: every 3 days
- f4: every 4 days
- f5: every 5 days
- ...


# Trigger a new test for an existing periodic job in Prow
Navigate to the app.ci console URL (For URL, search 'prow' in BitWarden). After logging in (via SSO) to this cluster using the console, use the link in the top right “Copy login command” to get your token.
Run the specific periodic job you want using REST API.
```
TOKEN='sha256~the_token_you_get_from_above'
GANGWAY_API='https://gangway***.com' # For API URL, search 'prow' in BitWarden
JOB_NAME='replace-me-eg-periodic-ci-openshift-openshift-tests-private-release-4.14-amd64-nightly-gcp-ipi-sdn-migration-ovn-p2-f7'
$ curl -X POST -d '{"job_execution_type": "1"}' -H "Authorization: Bearer ${TOKEN}" "${GANGWAY_API}/v1/executions/${JOB_NAME}"
{
 "id": "d7c56195-428f-4217-aab0-6f95b2f2e763",
 "job_name": "periodic-ci-openshift-openshift-tests-private-release-4.14-amd64-nightly-gcp-ipi-sdn-migration-ovn-p2-f7",
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
JOB_NAME='replace-me-eg-periodic-ci-openshift-openshift-tests-private-release-4.14-amd64-nightly-4.14-upgrade-from-stable-4.13-aws-ipi-network-mtu-localzone-p2-f14'
$ curl -X POST -d '{"job_execution_type": "1", "pod_spec_options": { "envs":  {"RELEASE_IMAGE_LATEST": "quay.io/openshift-release-dev/ocp-release:4.13.2-x86_64", "RELEASE_IMAGE_TARGET": "quay.io/openshift-release-dev/ocp-release:4.14.0-ec.1-x86_64"} } }' -H "Authorization: Bearer ${TOKEN}" "${GANGWAY_API}/v1/executions/${JOB_NAME}"
```
You can use `-v` option for curl to see detailed information about the request as well as error message.
