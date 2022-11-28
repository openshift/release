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
