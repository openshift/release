Multi-Payload Job Names
=======================

### What is the motivation?

The multiarch team is migrating many of the single-architecture payload jobs to use the
muli-architecture payload.  One of the difficulties when migrating these jobs is finding appropriately
descriptive names for any of these new jobs so they do not conflict with existing job names,
and reflect the nature of the cluster deployment.

### Name Fields Breakdown

Building upon the [Naming Your CI Jobs](https://docs.ci.openshift.org/docs/how-tos/naming-your-ci-jobs/) documentation, the following pattern will be used for the multiarch
jobs utilizing the multi-payload going forward:

```
... [TEST SUITE]-[PLATFORM]-[PAYLOAD]-[DEPLOYMENT STYLE]-[CONTROL PLANE ARCH]-[COMPUTE NODE ARCHITECTURE(S)]
```

The architectures will be represented in single character arrangements, with the following breakdown:

* `a` = `arm64`
* `p` = `ppc64le`
* `x` = `x86_64`
* `z` = `s390x`

### Job Name Examples
* `periodic-ci-openshift-multiarch-master-nightly-4.17-ocp-e2e-gcp-ovn-multi-x-ax`
  * e2e tests run in gcp using the multi payload with `x86_64` control plane and mixed `arm64` and `x86_64` compute nodes.
* `periodic-ci-openshift-multiarch-master-nightly-4.17-ocp-e2e-gcp-ovn-multi-day-0-x-ax`
  * e2e tests run in gcp using the multi payload with `x86_64` control plane and mixed `arm64` and `x86_64` compute nodes at deployment time (nodes not added later).
* `periodic-ci-openshift-multiarch-master-nightly-4.17-ocp-e2e-ibmcloud-ovn-multi-x-xz`
  * e2e tests run in ibmcloud using the multi payload with `x86_64` control plane and mixed `s390x` and `x86_64` compute nodes.
* `periodic-ci-openshift-multiarch-master-nightly-4.17-ocp-e2e-gcp-ovn-multi-a-a`
  * e2e tests run in gcp using the multi payload with `arm64` control plane and compute nodes
* `periodic-ci-openshift-multiarch-master-nightly-4.17-ocp-e2e-ovn-powervs-capi-multi-p-p`
  * e2e tests run in powervs using the multi payload with `ppc64le` control plane and compute nodes
* `periodic-ci-openshift-multiarch-master-nightly-4.17-ocp-e2e-ovn-remote-libvirt-multi-z-z`
  * e2e tests run in multiarch libvirt CI environment using the multi payload with `s390x` control plane and compute nodes
