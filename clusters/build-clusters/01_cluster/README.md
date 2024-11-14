# 01-Cluster

[01-Cluster](https://console-openshift-console.apps.build01.ci.devcluster.openshift.com) is an OpenShift-cluster managed by DPTP-team. It is one of the clusters for running Prow job pods.

## Installation

The aws account for installation of this cluster: [aws console](https://openshift-ci-infra.signin.aws.amazon.com/console).

The aws account is managed by [DPP team](https://issues.redhat.com/browse/DPP-3283) with the public hosted zone (base domain for installer): `ci.devcluster.openshift.com`.

To generate `install-config.yaml` after oc-cli logs in api.ci.openshift.org:

```
make generate-install-config
...
run 'cp /tmp/install-config.yaml ~/install-config.yaml' before installation the cluster
```

Check `[install_cluster.sh](./install_cluster.sh)` to see other prerequisites for installation. _Please ensure
cluster `build01` is destroyed before installing a new one_. This is to avoid the conflicting usage of AWS resources.

To install a Openshift 4 cluster:

```
$ make install-dptp-managed-cluster
```

Post-install action:

Once we install the cluster, store the installation directory somewhere in case we need to destroy the cluster later on.
Update password of `kubeadmin` in bitwarden (searching for item called `build_farm_build01 `).
The cert-based kubeconfig file is also uploaded to the same BW item (attachement `b01.admin.cert.kubeconfig`).

## Set up ci-admins

```
$ make set-up-ci-admins
```

## ClusterAutoscaler

[openshift.doc](https://docs.openshift.com/container-platform/4.1/machine_management/applying-autoscaling.html)

We use aws-region `us-east-1` for our clusters: They are 6 zones in it:

```
$ aws ec2 describe-availability-zones --region us-east-1 --filter Name=zone-type,Values=availability-zone | jq -r .AvailabilityZones[].ZoneName
us-east-1a
...
us-east-1f

```

We set autoscaler for 3 zones where the masters are: `us-east-1a`, `us-east-1b`, and `us-east-1c`.

To generate `MachineAutoscaler`s:

```
$ make generate-machine-autoscaler
```

To set up autoscaler:

```
$ make set-up-autoscaler
```

Then we should see the pod below running:

```
$ oc get pod -n openshift-machine-api -l cluster-autoscaler=default
NAME                                          READY     STATUS    RESTARTS   AGE
cluster-autoscaler-default-576944b996-h82zp   1/1       Running   0          7m54s
```

## Prow Configuration for build cluster

### Deploy admin assets: Manual
Deploy `./**/admin_*.yaml`.

### Deploy non-admin assets
Automated by [branch-ci-openshift-release-master-build01-apply](https://github.com/openshift/release/blob/0ac7c4c6559316a5cf40c40ca7f05a0df150ef8d/ci-operator/jobs/openshift/release/openshift-release-master-postsubmits.yaml#L9) and [Prow's config-updater plugin](https://github.com/openshift/release/blob/0ac7c4c6559316a5cf40c40ca7f05a0df150ef8d/core-services/prow/02_config/_plugins.yaml#L198).

### CA certificates: Semi-Manual

It is semi-manual because rotation of the CAs is automated and patching to config (needed only once) is not.

#### API server CA
Manual steps

* [Set up aws IAM user](https://cert-manager.io/docs/configuration/acme/dns01/route53/#set-up-an-iam-role): user `cert-manager` in group `cert-manager` which has the policy `cert-manager`.

* Use `cert-manager` to generate the secret containing the certificates:

```bash
$ oc  --context build01 get secret -n openshift-config apiserver-build01-tls
NAME                    TYPE                DATA   AGE
apiserver-build01-tls   kubernetes.io/tls   3      6d21h
```

Use the secret in apiserver's config:

> oc patch apiserver cluster --type=merge -p '{"spec":{"servingCerts": {"namedCertificates": [{"names": ["api.build01.ci.devcluster.openshift.com"], "servingCertificate": {"name": "apiserver-build01-tls"}}]}}}' 

Verify if it works:

```
$ curl --insecure -v https://api.build01.ci.devcluster.openshift.com:6443 2>&1 | awk 'BEGIN { cert=0 } /^\* Server certificate:/ { cert=1 } /^\*/ { if (cert) print }'
* Server certificate:
*  subject: CN=api.build01.ci.devcluster.openshift.com
*  start date: Jun 30 13:17:41 2020 GMT
*  expire date: Sep 28 13:17:41 2020 GMT
*  issuer: C=US; O=Let's Encrypt; CN=Let's Encrypt Authority X3
*  SSL certificate verify ok.
* Connection state changed (HTTP/2 confirmed)
* Copying HTTP/2 data in stream buffer to connection buffer after upgrade: len=0
* Using Stream ID: 1 (easy handle 0x7f8c80808200)
* Connection state changed (MAX_CONCURRENT_STREAMS == 2000)!
* Connection #0 to host api.build01.ci.devcluster.openshift.com left intact

```

#### App domain: see [readme](../openshift-ingress-operator/README.md)
Use `cert-manager` to generate the secret containing the certificates:

```bash
$ oc  --context build01 get secret -n openshift-ingress apps-tls
NAME               TYPE                DATA   AGE
apps-tls   kubernetes.io/tls   3      6d23h
```

Use the secret in apiserver's config: manual step only for test, see [default_ingresscontroller.yaml](openshift-ingress-operator/default_ingresscontroller.yaml)

> oc patch ingresscontroller.operator default \
     --type=merge -p \
     '{"spec":{"defaultCertificate": {"name": "apps-tls"}}}' \
     -n openshift-ingress-operator

Verify if it works:

```
$ curl --insecure -v https://default-route-openshift-image-registry.apps.build01.ci.devcluster.openshift.com 2>&1 | awk 'BEGIN { cert=0 } /^\* Server certificate:/ { cert=1 } /^\*/ { if (cert) print }'
* Server certificate:
*  subject: CN=*.apps.build01.ci.devcluster.openshift.com
*  start date: Jun 30 13:17:41 2020 GMT
*  expire date: Sep 28 13:17:41 2020 GMT
*  issuer: C=US; O=Let's Encrypt; CN=Let's Encrypt Authority X3
*  SSL certificate verify ok.
* Connection #0 to host default-route-openshift-image-registry.apps.build01.ci.devcluster.openshift.com left intact

```


### update BW items: Semi-Manual

The item `build_farm` contains
	
* `sa*config`: those are `kubeconfig` for different `SAs`
* `build01_ci_reg_auth_value.txt` and `build01_build01_reg_auth_value.txt` are used to form pull secrets for `ci-operator`'s tests.

Use [generate-bw-items.sh](./hack/generate-bw-items.sh) to generate those files, and upload them to the BW item `build_farm`.

### Populate secrets on build01 for prow and tests

Use [ci-secret-bootstrap](../../../core-services/ci-secret-bootstrap/README.md).

## OpenShift Image Registry: 

It is automated by config-updater:

* customized URL
* `replicas=3`

## OpenShift-Monitoring

It is automated by config-updater:

* alertmanager secret for sending notification to slack
* PVCs for monitoring stack

## Upgrade the cluster

### Upgrading inside the same minor version

Upgrading inside the same minor version of `build01` is automated by [periodic-build01-upgrade](https://github.com/openshift/release/blob/67d13e6adaa3a061b18839176c2e26b3547a924d/ci-operator/jobs/infra-periodics.yaml#L8).

### Upgrading between minor versions

Modify channel configuration, e.g., from OCP 4.3 to 4.4:

```
oc --as system:admin --context build01 patch clusterversion version --type json -p '[{"op": "add", "path": "/spec/channel", "value": "candidate-4.4"}]'
```

### Run the upgrade command

For example, upgrade to 4.5.4

```
oc --as system:admin --context build01 adm upgrade --to=4.5.4
```

## Destroy the cluster

_Note_: [Remove the build01 config from plank](https://github.com/openshift/release/pull/6922). It would cause plank to crash otherwise.

Before recreating `build01` cluster, we need to destroy it first.

```bash
### Assume you have aws credentials file ${HOME}/.aws/credentials ready for ci-infra account
### google drive folder shared within DPTP-team
### download/unzip/cd ./build01/20191016_162227.zip
$ openshift-install destroy cluster --log-level=debug
```
