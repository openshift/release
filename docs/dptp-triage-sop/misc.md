Probe Failing on ci-rpms
========================

```
[FIRING:1] ProbeFailing blackbox (https://artifacts-rpms-openshift-origin-ci-rpms.apps.ci.l2s4.p1.openshiftapps.com/openshift-origin-v3.11/repodata/repomd.xml critical)
Probing the instance https://artifacts-rpms-openshift-origin-ci-rpms.apps.ci.l2s4.p1.openshiftapps.com/openshift-origin-v3.11/repodata/repomd.xml has been failing for the past minute.
```

The TP team does not own these services.

Resolution before [DPTP-2981](https://issues.redhat.com/browse/DPTP-2981) is completed:

```bash
oc --context app.ci delete --all pods --namespace=ci-rpms
```

Probe Failing on deck-internal
==============================

```
[FIRING:1] deck-internalDown (critical)
The service deck-internal has been down for 5 minutes.
```

Resolution before [DPTP-2712](https://issues.redhat.com/browse/DPTP-2712) is completed:

```bash
oc --context app.ci delete pod -n ci -l app=prow,component=deck-internal
```

Access internal job logs
========================

For jobs available in [deck-internal](https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/), the logs are stored in GCP project `openshift-ci-private`, bucket `origin-ci-private`.

The logs can be deleted in case of leak of secrets or other sensitive information.

quay-io-image-mirroring-failures
================================

The alert is fired if there are many failures of `oc image mirror` in `ci-images-mirror`.

Choose a method below - pod logs, cloudwatch or splunk - and then we can run the command locally in our computer:

```bash
# get the credentials
$ oc -n ci extract secret/registry-push-credentials-ci-images-mirror --to=- --keys .dockerconfigjson | jq > /tmp/qci.json
# the source and the target are taken from the log
$ oc image mirror --keep-manifest-list --registry-config=/tmp/qci.json --continue-on-error registry.ci.openshift.org/origin/scos-4.16:cluster-capi-operator=quay.io/openshift/ci:origin_scos-4.16_cluster-capi-operator
```

If it reproduces the same error, mostly, it is caused by a broken source image. In that case, we should
- Fix the source image, e.g. by rebuilding the image from **Pod logs** example below:
  - Inside `release` repo search for the job that promotes the image: `grep -r 'to: cluster-capi-operator'`
  - Observe the directory three of the returned files: `ci-operator/config/openshift/cluster-capi-operator/`
  - Find the equivalent `ProwJob`, e.g. `ci-operator/jobs/openshift/cluster-capi-operator/openshift-cluster-capi-operator-release-4.16-postsubmits.yaml`
  - Pick the right `ProwJob` from the file, e.g. `branch-ci-openshift-cluster-capi-operator-release-4.16-okd-scos-images`
  - Execute from inside `release` repository: `make job JOB='branch-ci-openshift-cluster-capi-operator-release-4.16-okd-scos-images' BASE_REF=release-4.16`
- Ignore the mirroring otherwise: See [RFE-5363](https://issues.redhat.com/browse/) for example.


Pod logs
--------

The pod has the logs to show the details:

```bash
oc logs -n ci -l app=ci-images-mirror -c ci-images-mirror | grep -E 'Running command failed|manifest unknown'
```

Example:

```
 {"args":"image mirror --keep-manifest-list --registry-config=/etc/push/.dockerconfigjson --continue-on-error --max-per-registry=20 registry.ci.openshift.org/origin/scos-4.16:cluster-capi-operator=quay.io/openshift/ci:origin_scos-4.16_cluster-capi-operator registry.ci.openshift.org/origin/scos-4.13:vertical-pod-autoscaler-operator=quay.io/openshift/ci:origin_scos-4.13_vertical-pod-autoscaler-operator","client":"/usr/bin/oc","component":"ci-images-mirror","error":"exit status 1","file":"/go/src/github.com/openshift/ci-tools/pkg/controller/quay_io_ci_images_distributor/oc_quay_io_image_helper.go:49","func":"github.com/openshift/ci-tools/pkg/controller/quay_io_ci_images_distributor.(*ocExecutor).Run","level":"debug","msg":"Running command failed.","output":"quay.io/
error: unable to retrieve source image registry.ci.openshift.org/origin/scos-4.16 manifest #1 from manifest list: manifest unknown: manifest unknown
```

The logs above indicates `unable to retrieve source image registry.ci.openshift.org/origin/scos-4.16 manifest #1 from manifest list: manifest unknown: manifest unknown`, following the message we can see that the manifest is `registry.ci.openshift.org/origin/scos-4.16:cluster-capi-operator`

CloudWatch:
-----------

```txt
fields @timestamp,structured.component as component,structured.msg as msg,structured.args as args, @message, @logStream, @log
| filter(component="ci-images-mirror" and msg="Running command failed." and (args like /image mirror.*/))
| sort @timestamp desc 
| limit 20
```

Example: 

```json
{
    "args": "image mirror --keep-manifest-list --registry-config=/etc/push/.dockerconfigjson --continue-on-error=true --max-per-registry=20 --dry-run=false quay.io/jetstack/cert-manager-webhook:v1.11.4=quay.io/openshift/ci:ci_cert-manager-webhook_v1.11.4 quay.io/app-sre/boilerplate:image-v2.0.1=quay.io/openshift/ci:openshift_boilerplate_image-v2.0.1 quay.io/jetstack/cert-manager-cainjector:v1.9.1=quay.io/openshift/ci:ci_cert-manager-cainjector_v1.9.1 registry.access.redhat.com/ubi8/ubi-minimal:latest=quay.io/openshift/ci:origin_ubi-minimal_8 quay.io/apicurio/apicurio-ci-tools:interop=quay.io/openshift/ci:ci_apicurio-ci-tools_interop quay.io/edge-infrastructure/assisted-service-index:ocm-2.6=quay.io/openshift/ci:edge-infrastructure_assisted-service-index_ocm-2.6 quay.io/cvpops/operator-scorecard:v8=quay.io/openshift/ci:ci_cvp-operator-scorecard_v8 registry.fedoraproject.org/fedora:latest=quay.io/openshift/ci:ci_fedora_latest quay.io/redhatqe/insights-operator-tests:latest=quay.io/openshift/ci:ci_insights-operator-tests_latest quay.io/app-sre/boilerplate:image-v0.1.1=quay.io/openshift/ci:openshift_boilerplate_image-v0.1.1",
    "client": "/usr/bin/oc",
    "component": "ci-images-mirror",
    "error": "exit status 1",
    "file": "/go/src/github.com/openshift/ci-tools/pkg/controller/quay_io_ci_images_distributor/oc_quay_io_image_helper.go:49",
    "func": "github.com/openshift/ci-tools/pkg/controller/quay_io_ci_images_distributor.(*ocExecutor).Run",
    "level": "debug",
    "msg": "Running command failed.",
    "output": "...\nerror: unable to push manifest to quay.io/openshift/ci:ci_fedora_latest: manifest invalid: manifest invalid\ninfo: Mirroring completed in 940ms (0B/s)\nerror: one or more errors occurred\n",
    "severity": "debug",
    "time": "2024-04-03T12:48:01Z"
}
```

The logs above indicates `quay.io/openshift/ci:ci_cert-manager-cainjector_v1.9.1\nerror: unable to push manifest to quay.io/openshift/ci:ci_fedora_latest: manifest invalid: manifest` is the problem.

Splunk
------

```txt
index="rh_dptp-001" openshift.cluster_id="248ca8f0-5af8-4a45-a153-d2d9125390dd" kubernetes.namespace_name="ci" kubernetes.labels.app="ci-images-mirror" ("Running command failed")
```

Example:

```json
{
    "message" : {"args":"image mirror --keep-manifest-list --registry-config=/etc/push/.dockerconfigjson --continue-on-error=true --max-per-registry=20 registry.ci.openshift.org/ocp/builder:rhel-9-base-nodejs-openshift-4.19.art-arm64=quay.io/openshift/ci:ocp_builder_rhel-9-base-nodejs-openshift-4.19.art-arm64 registry.ci.openshift.org/origin/scos-4.16:cluster-capi-operator=quay.io/openshift/ci:origin_scos-4.16_cluster-capi-operator registry.ci.openshift.org/origin/scos-4.13:vertical-pod-autoscaler-operator=quay.io/openshift/ci:origin_scos-4.13_vertical-pod-autoscaler-operator","msg":"Running command failed.","output":"...\nerror: unable to retrieve source image registry.ci.openshift.org/origin/scos-4.16 manifest #1 from manifest list: manifest unknown: manifest unknown\n\ninfo: Mirroring completed in 4.54s (0B/s)\nerror: one or more errors occurred\n","severity":"debug","time":"2025-02-12T13:52:27Z"} 
}
```

The logs above indicates `unable to retrieve source image registry.ci.openshift.org/origin/scos-4.16 manifest #1 from manifest list: manifest unknown: manifest unknown`, following the message we can see that the manifest is `registry.ci.openshift.org/origin/scos-4.16:cluster-capi-operator`
