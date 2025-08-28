This directory contain the steps, chains and workflows implemented specifically for the Openshift Sandboxed Containers (OSC) jobs.

## Steps

Here is the list of steps and their explanation.

Please refer to the `*-ref.yaml` file in their source code for the full list of parameters accepted by each step.

### sandboxed-containers-operator-get-kata-rpm

The [sandboxed-containers-operator-get-kata-rpm](./get-kata-rpm/) step downloads the kata-containers rpm from Brew and copy it over the cluster worker nodes.

This step run in a `upi-installer` container, therefore, the image should be referenced
in the `base_images` section of the job's yaml, as for example:

```yaml
base_images:
  upi-installer:
    name: "4.18"
    namespace: ocp
    tag: upi-installer
```

### sandboxed-containers-operator-peerpods-param-cm

The [sandboxed-containers-operator-peerpods-param-cm](./peerpods/param-cm/) step creates the peerpods-param-cm configmap. Currently only Azure is supported and it will do the needed networking setup for OSC to work properly on this cloud provider.

### sandboxed-containers-operator-env-cm

The [sandboxed-containers-operator-env-cm](./env-cm/) step creates the osc-config configmap which is actually used by the OSC tests in `platform-extended-tests` to control many aspects of the execution. In case this step is not reference, default values will be used by the tests.

Currently not all parameters are enabled. In particular, only GA release type is supported, meaning it doesn't install development builds of OSC.

## Chains

Here is the list of chains.

### sandboxed-containers-operator-pre

The [sandboxed-containers-operator-pre](./pre/) chain wraps the steps that prepare the environment for executing the tests.

This chain is meant to be referenced in the `pre` condition of the workflow.

### sandboxed-containers-operator-ipi-azure-pre

The [sandboxed-containers-operator-ipi-azure-pre](./ipi/azure-pre/) chain customize [ipi-azure-pre](../ipi/azure/pre/)
to allow creating the Openshift cluster by default in the **eastus** region of Azure.

## workflows

Here is the list of workflows.

### sandboxed-containers-operator-e2e-azure

The [sandboxed-containers-operator-e2e-azure](./e2e/azure/) workflow implements an entire e2e execution for testing OSC on Azure. It will deploy Openshift on Azure, evoke the [sandboxed-containers-operator-pre](#sandboxed-containers-operator-pre) chain for preparing the environment and finally execute the `platform-extended-tests`.

As the [openshift-extended-test](../openshift-extended/test/) step is referenced in the `test` condition, any job using this workflow should import the `tests-private` image. This is done by adding an entry to the `base_images` section in the job's yaml, as for example:

```yaml
base_images:
  tests-private:
    name: tests-private
    namespace: ci
    tag: "4.18"
```

> **Important:** updates to our tests in `platform-extended-tests` are made to `master` and never backported to release branches, however, the `tests-private` image hasn't `latest` builds from the `master` branch. Meaning that if you need to pick the latest and greatest code of `platform-extended-tests` then you must find and use the latest image version available at that point in time (usually it is next major OCP version under development).

## Managing secrets

There are some steps (e.g. sandboxed-containers-operator-get-kata-rpm) that require access to secrets. Our secrets are stored on Vault’s key-value engine at https://vault.ci.openshift.org/ under the `sandboxed-containers-operator/sandboxed-containers-operator-ci-secrets` path.

In case you want to manage secrets on that path, first must log-in https://selfservice.vault.ci.openshift.org at least once, then ask @tbuskey, @ldoktor or @wainersm to add you in the list of members of the `sandboxed-containers-operator` collection. Please refer to https://docs.ci.openshift.org/docs/how-tos/adding-a-new-secret-to-ci/ for further information.
