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

## Clusterbot

The [sandboxed-containers-operator-e2e-azure](./e2e/azure/) and
[sandboxed-containers-operator-e2e-azure](./e2e/aws/) workflows are
available in [clusterbot](https://github.com/openshift/ci-chat-bot/blob/main/README.md).
You have 2 main options:

* ``workflow-launch``
  * creates OCP cluster
  * gives you KUBECONFIG via clusterbot
  * **does not install OSC**, but prepares cm and mirrorlists to let you install it yourself via ``extended-platform-tests``
  * allows extended reservation via ``SLEEP_DURATION`` timeout, but you have to delete ``launch-cucushift-installer-wait`` pod do return it!
* ``workflow-test``
  * creates OCP cluster
  * clusterbot will not send you KUBECONFIG, but you can obtain it from the build farm secrets
  * allows creating multiple OCP clusters concurrently
  * allows extended reservation after the testing is done via ``SLEEP_DURATION`` timeout, but you have to delete ``launch-cucushift-installer-wait`` pod do return it!
  * **can install OSC** when any of ``[sig-kata]`` tests are specified in ``TEST_SCENARIOS`` parameter
  * can be used to simply test your RPM/scratch/... build against the usual set of sig-kata tests by setting ``TEST_SCENARIOS`` and ``SLEEP_DURATION=0`` (to avoid the need to return the cluster)

**Please always return the clusters as soon as possible, they do not
use spot-instances so they are costly. With ``SLEEP_DURATION=0``
(by default) they will be torn down automatically after the testing,
with ``SLEEP_DURATION!=0`` you have to wait for the
``cucushift-installer-wait`` phase and manually delete the
``launch-cucushift-installer-wait`` pod from the ``main build OCP``.
The ``done`` command will not interrupt this step!**

For azure you don't need to cleanup any extra resources created
on the cluster, but **you have to cleanup any extra resources
(like AMI images, snapshots and S3 buckets!) on AWS** otherwise
they'll stay there forever, costing us real money!

### Workflow overview

Cloud overview:

```
+------------------+     +---------------+
|  main build OCP  | --> |  testing OCP  |
+------------------+     +---------------+
```

* ``main build OCP`` installs the testing OCP and runs the steps
  required to run the workflow (like openshift-tests, sleep,
  deprovisioning) and it contains all the secrets required
  for the job and is responsible for returning the cluster
  when the ``testing OCP`` is destroyed
* ``testing OCP`` is the actual OCP to-be-tested by you

Workflow overview:

```
                                                                       workflow-test
                                                                +-------------------------+
                      +----------------------------------+      | extended-platform-tests |
                      | configure configmaps/mirrorlists |  +-> | $TEST_SCENARIOS         | -+
+---------------+     | to run extended-platform-tests   |  |   | (oc get cm/osc-config)  |  |   +--------------------------+     +-----------------+
| provision OCP | --> | [sig-kata] tests                 | -+   +-------------------------+  +-> | cucushift-installer-wait | --> | deprovision OCP |
+---------------+     | $ENABLEPEERPODS,$INSTALL_KATA_R  |  |                                |   | $SLEEP_DURATION          |     +-----------------+
                      | PM,$KATA_RPM_VERSION,$WORKLOAD_  |  |      +------------------+      |   +--------------------------+
                      | TO_TEST,$CATALOG_SOURCE_IMAGE,.. |  +----> | clusterbot sleep | -----+
                      +----------------------------------+         +------------------+
                                                                     workflow-launch
```

### Usual workflows

Copy, paste & modify those examples to clusterbot to use our workflow,
replace the suffix `-azure` with `-aws` to do the same on `aws`:

* Check your kata-container.rpm from brew via ``KATA_RPM_BUILD_TASK`` (no need to return these, you'll get the status via slack as well as url to check the individual test results):
  * kata - ``workflow-test sandboxed-containers-operator-e2e-azure 4.18 "SLEEP_DURATION=0s","KATA_RPM_BUILD_TASK=68341465","ENABLEPEERPODS=false","RUNTIMECLASS=kata","TEST_SCENARIOS=sig-kata.*","WORKLOAD_TO_TEST=kata","TEST_TIMEOUT=90"``
  * peer-pods - ``workflow-test sandboxed-containers-operator-e2e-azure 4.18 "SLEEP_DURATION=0s","KATA_RPM_BUILD_TASK=68341465","ENABLEPEERPODS=true","RUNTIMECLASS=kata-remote","TEST_SCENARIOS=sig-kata.*","WORKLOAD_TO_TEST=peer-pods","TEST_TIMEOUT=90"``
  * coco - ``workflow-test sandboxed-containers-operator-e2e-azure 4.18 "SLEEP_DURATION=8h","KATA_RPM_BUILD_TASK=68341465","ENABLEPEERPODS=true","RUNTIMECLASS=kata-remote","TEST_SCENARIOS=sig-kata.*","WORKLOAD_TO_TEST=coco","TEST_TIMEOUT=90"``
* Get a cluster without OSC installed for ~8h - ``workflow-launch sandboxed-containers-operator-e2e-azure 4.18 "SLEEP_DURATION=8h"`` (clusterbot will send you ``KUBECONFIG`` of the testing OSC, you can use ``extended-platform-tests`` to install sandboxed constainers operator as all the config maps are prepared, you need to use ``done`` followed by deleting the ``launch-cucushift-installer-wait`` pod from the ``main build OCP`` to return it)
* Get a cluster with OSC installed for ~8h - ``workflow-test sandboxed-containers-operator-e2e-azure 4.18 "SLEEP_DURATION=8h","ENABLEPEERPODS=true","RUNTIMECLASS=kata-remote","TEST_SCENARIOS=sig-kata.*Operator installation","WORKLOAD_TO_TEST=peer-pods","TEST_TIMEOUT=90"`` (clusterbot will **not** notify you nor give you ``KUBECONFIG``, see below how to get access; after the testing you have to delete the ``launch-cucushift-installer-wait`` pod from the ``main build OCP`` to return it)

### AWS Cleanup

Unlike in Azure in **AWS you are responsible for deleting all
extra resources you created (AMI images, snapshots, S3 buckets)**
The main source of left-overs usually is kataconfig, you can
delete it by:

```
count=0;
interval=120 # seconds
maxcount=<20 minutes>
oc delete kataconfig example-kataconfig
while [$count -lt $maxcount ] ; do
  if [ $(oc get kataconfig example-kataconfig) == "not found" ]
  then
    exit 0
  fi
  sleep $interval
  count=$count+$interval
done
echo "timed out"
exit 1
```

Alternatively delete AMI **and** the associated snapshot manually.

### Using workflow-launch cluster

Simply wait for clusterbot to hand you over the credentials of the
``testing OCP``. If you need to access (for whatever reason) the
``main build OCP`` you can simply open the link clusterbot sent
you ``a cluster is being created...`` and in the ``Build Log``
click on the link next to ``Using namespace ...`` line close to
the beginning of the log.

Ignore any of the ``expired`` messages from cluster bot, the cluster
is available to you as long as the workflow pods are running inside
the ``main build OCP``.

This workflow never installs sandboxed containers operator by itself
but you can use ``extended-platform-tests`` to mimic what the main
workflow does, see ``Running extended-platform-tests...`` sections
for details.

Out of the box you get 2.5h by clusterbot which can be returned
earlier by ``done`` command, **but** if you needed more and specified
``SLEEP_DURATION`` parameter the ``done`` command **will not**
return the cluster. You have to connect to the ``main build OCP``
and delete the ``launch-cucushift-installer-wait`` pod
(if it doesn't exists the clusterbot one might be still
running. Return via ``done`` first and wait for the
``launch-cucushift-installer-wait`` one to appear and delete it. Note
deletion takes some time (unless you specify ``--now``).

### Using workflow-test cluster

This workflow executes the standard testing, therefore clusterbot
will not notify and will not give you the ``KUBECONFIG``. On the
other hand you can specify ``TEST_SCENARIOS`` and let the job
to configure OCP including sandboxed-containers-operator deployment.

If you only care about the results, simply keep the ``SLEEP_DURATION=0s``
and clusterbot will let you know about the results and deprovisions
the cluster. This way you don't need to return anything manually.

If you need to interact with the cluster, you can specify
``SLEEP_DURATION=XXXh`` parameter which launches the workflow
and when the testing is over it will ``sleep XXXh`` afterwards.
**You will not** be notified by clusterbot about this and you
have to poll the job logs for that. To do so open the
``job started, you will be notified on completion``
link by clusterbot and unwrap the ``Build Log``. Search
for ``Running step launch-cucushift-installer-wait.`` line
in there. Once it shows there the cluster is ready and waiting
for you for the specified amount of time.

Getting access to your testing cluster is slightly harder as first 
you need to get to the ``main build OCP``. To do so:

1. open the ``job started...`` link by clusterbot
2. unwrap the ``Build Log``
4. click on the link next to ``Using namespace ...`` (close to
   the beginning of the log
5. Login via SSO
6. look at ``secrets/launch`` and find ``kubeconfig`` entry there,
   which is the ``KUBECONFIG`` of your ``testing OCP``.

*Alternatively after step (5) you can click on your name in
top-right area and click on ``Copy login command``, login
to this ``main build OCP`` and extract the ``KUBECONFIG`` by
``oc get secrets/launch -o jsonpath='{.data.kubeconfig}' | base64 -d``*

Using that KUBECONFIG you should be able to interact with
the ``testing OCP`` and provided it ran any of the ``[sig-kata]``
tests before (and they succeeded) the OSC should be installed
(double-check by ``oc get all -n openshift-sandboxed-containers-operator``).

To return this cluster you **can not** use the ``done`` clusterbot
command (as a matter of fact you can actually request multiple OCPs).
If you did not specified the ``SLEEP_DURATION`` then you can
simply leave it and it'll return the cluster right after the
testing (you can interrupt the testing by destroying the
``launch-openshift-extended-test`` pod on the ``main build OCP``).
If you specified the ``SLEEP_DURATION`` **you have to interrupt**
the ``launch-cucushift-installer-wait`` pod, otherwise it will
sleep and hold the cluster for the whole ``SLEEP_DURATION`` period.
Note there might be other pods as well based on the stage the
workflow is in, I'd suggest not interrupting the ipi/provisioning/...
stages but once your cluster reaches ``cucushift-installer-wait``
stage you should delete the ``launch-cucushift-installer-wait``

An example for demonstration purposes:

```bash
# login to main build OCP
oc login --token=XXX --server=https://YYY:6443

# get the workflow pods
oc get pods
NAME                                                          READY   STATUS      RESTARTS   AGE
launch-azure-provision-custom-role                            0/2     Completed   0          65m
launch-azure-provision-service-principal-minimal-permission   0/2     Completed   0          65m
launch-ipi-azure-rbac                                         0/2     Completed   0          4m44s
launch-ipi-conf                                               0/2     Completed   0          67m
launch-ipi-conf-azure                                         0/2     Completed   0          66m
launch-ipi-conf-azure-custom-region                           0/2     Completed   0          66m
launch-ipi-conf-telemetry                                     0/2     Completed   0          66m
launch-ipi-install-hosted-loki                                0/2     Completed   0          64m
launch-ipi-install-install                                    0/2     Completed   0          64m
launch-ipi-install-monitoringpvc                              0/2     Completed   0          66m
launch-ipi-install-rbac                                       0/2     Completed   0          64m
launch-ipi-install-times-collection                           0/2     Completed   0          5m11s
launch-multiarch-validate-nodes                               0/2     Completed   0          4m52s
launch-nodes-readiness                                        0/2     Completed   0          5m1s
launch-openshift-cluster-bot-rbac                             0/2     Completed   0          64m
launch-openshift-extended-test                                2/2     Running     0          2m9s
launch-sandboxed-containers-operator-env-cm                   0/2     Completed   0          2m16s
launch-sandboxed-containers-operator-get-kata-rpm             0/2     Completed   0          4m36s
launch-sandboxed-containers-operator-peerpods-param-cm        0/2     Completed   0          3m14s
release-images-latest                                         0/2     Completed   0          68m
release-images-latest-cli                                     0/1     Completed   0          69m

# Note there is no launch-cucushift-installer-wait pod running
# because the workflow is still in the openshift-extended-test
# phase. To return the cluster you have to first interrupt that
# one, wait for the launch-cucushift-installer-wait to appear
# and delete it as well

oc delete --now pods/launch-openshift-extended-test
oc get pods
...
launch-cucushift-installer-wait                                2/2     Running     0          12s
...
oc delete --now pods/launch-cucushift-installer-wait

# new "Running" pods will appear to cleanup and return the cluster
# DO NOT DELETE THEM!
```

### Running openshift-extended-test from your laptop

The ``[sig-kata]`` tests are currently not upstream so you have to
download the internal openshift-extended-test from github and build
it (feel free to ping OWNERS via slack/email to get the link)

```bash
git clone XXX
cd XXX
make
```

Once they are built you can run any of the tests. To only install
the operator and finish you can use something like this:

```bash
extended-platform-tests run --max-parallel-tests 1 --provider azure -o ./RESULTS/extended.log --timeout 75m --junit-dir=./RESULTS/logs --include-success --count 1 --run=".*\[sig-kata\].*Operator install.*" all
```

### Running openshift-extended-tests using podman

First you need to get ``docker://registry.ci.openshift.org/ci/tests-private``
which is not publicly available. The simplest way to do it is
to login to the ``main build OCP`` or to your ``testing OCP``
and extract the pull-secrets:

```bash
# login to main build OCP
oc login --token=XXX --server=https://YYY:6443

# get the pull secret (note for "testing OCP" you need to get them from
# "-n openshift-config", on "main build OCP" from the current project)
oc get secrets/pull-secret -o json | jq -r '.data.".dockerconfigjson"' |  base64 -d | jq -r '.auths."registry.ci.openshift.org".auth' | base64 -d
```

Now we can use the ``$username:$password`` to login to the registry:

```bash
# login to docker://registry.ci.openshift.org/ci/tests-private
# using the first part as username and second part as password
podman login registry.ci.openshift.org
Username: XXX
Password: YYY
Login Succeeded!
# Pull the contianer
podman pull registry.ci.openshift.org/ci/tests-private:latest
```

Unless you're looking for an updated version you don't need to re-login again
and simply use the pulled container. Still it might be worth updating it
from time to time...

Now we are almost ready to use the suite, storing the results
in current dir, there are just a few things the image does not
containe:

```bash
# First we need to deploy a "oc" binary, one way is to copy it
# to the local directory and pass it as a volume
cp `which oc` .

# Now ensure your $KUBECONFIG points to the "testing OCP" and
# not to the "main build OCP"
oc get nodes
NAME                                             STATUS   ROLES                  AGE    VERSION
ci-ln-njbpnn2-1d09d-hhfrp-master-0               Ready    control-plane,master   106m   v1.31.10
ci-ln-njbpnn2-1d09d-hhfrp-master-1               Ready    control-plane,master   106m   v1.31.10
ci-ln-njbpnn2-1d09d-hhfrp-master-2               Ready    control-plane,master   106m   v1.31.10
ci-ln-njbpnn2-1d09d-hhfrp-worker-eastus2-t6sh9   Ready    kata-oc,worker         95m    v1.31.10
ci-ln-njbpnn2-1d09d-hhfrp-worker-eastus3-bfkml   Ready    kata-oc,worker         91m    v1.31.10

# We are ready
podman run --rm -it -e KUBECONFIG=/kubeconfig -v $KUBECONFIG:/kubeconfig:z -v ./oc:/usr/bin/oc:z -v .:/RESULTS:z registry.ci.openshift.org/ci/tests-private extended-platform-tests run --max-parallel-tests 1 --provider azure -o /RESULTS/extended.log --timeout 75m --junit-dir=/RESULTS/logs --include-success --count 1 --run=".*\[sig-kata\].*Operator install.*" all
```

### Running openshift-extended-tests from main build OCP

This is similar to how ``prow`` executes the workflow, although it
requires a few tricks and obviously you need to be logged in to
the ``main build OCP`` as you'll be executing the pod from there.

```bash
# login to main build OCP (see chapter Using workflow-launch cluster)
oc login --token=XXX --server=https://YYY:6443

# create the testing pod using tests-private image
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test
spec:
  containers:
  - name: test
    image: registry.ci.openshift.org/ci/tests-private:latest
    command: ["bash"]
    stdin: true
    tty: true
    volumeMounts:
    - name: kubeconfig
      mountPath: /tmp/kube
      readOnly: true
  volumes:
  - name: kubeconfig
    secret:
      secretName: launch
      items:
      - key: kubeconfig
        path: config
  restartPolicy: Never
EOF

# prepare it for execution (oc and KUBECONFIG)
oc attach -it pod/test
cd /tmp
curl -L https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz | tar -xz
chmod +x oc
mkdir RESULTS
export PATH="$PATH:/tmp"
export KUBECONFIG=/tmp/kube/config

# now you can run the testing
extended-platform-tests run --max-parallel-tests 1 --provider azure -o ./RESULTS/extended.log --timeout 75m --junit-dir=./RESULTS/logs --include-success --count 1 --run=".*\[sig-kata\].*Operator install.*" all

# download the results
# detach from the attached pod by ``ctrl+p ctrl+q`` (or run in another terminal)
oc exec pod/test -- tar -cf - /tmp/RESULTS | tar -xf - -C .
# destroy your pod to allow cleanup
oc delete pod/test --now
```
When using this method ensure you delete all pods you created from the
``main build OCP`` otherwise it'll be blocked until the hard timeout.
