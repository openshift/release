## Probe Failing on ci-rpms

```
[FIRING:1] ProbeFailing blackbox (https://artifacts-rpms-openshift-origin-ci-rpms.apps.ci.l2s4.p1.openshiftapps.com/openshift-origin-v3.11/repodata/repomd.xml critical)
Probing the instance https://artifacts-rpms-openshift-origin-ci-rpms.apps.ci.l2s4.p1.openshiftapps.com/openshift-origin-v3.11/repodata/repomd.xml has been failing for the past minute.
```

The TP team does not own these services.

Resolution before [DPTP-2981](https://issues.redhat.com/browse/DPTP-2981) is completed:

> oc --context app.ci delete --all pods --namespace=ci-rpms

## Probe Failing on deck-internal

```
[FIRING:1] deck-internalDown (critical)
The service deck-internal has been down for 5 minutes.
```

Resolution before [DPTP-2712](https://issues.redhat.com/browse/DPTP-2712) is completed:

> oc --context app.ci delete pod -n ci -l app=prow,component=deck-internal

## Access internal job logs
For jobs available in [`deck-internal`](https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/), the logs are stored in GCP project `openshift-ci-private`, bucket `origin-ci-private`.

The logs can be deleted in case of leak of secrets or other sensitive information.


## quay-io-image-mirroring-failures

The alert is fired if there are many failures of `oc image mirror` in `ci-images-mirror`.
The pod has the logs to show the details:

> oc logs -n ci -l app=ci-images-mirror -c ci-images-mirror | grep "Running command failed." | grep "image mirror"

Or on CloudWatch:

```txt
fields @timestamp,structured.component as component,structured.msg as msg,structured.args as args, @message, @logStream, @log
| filter(component="ci-images-mirror" and msg="Running command failed." and (args like /image mirror.*/))
| sort @timestamp desc 
| limit 20
```

Example, 

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

The above log line indicates "quay.io/openshift/ci:ci_cert-manager-cainjector_v1.9.1\nerror: unable to push manifest to quay.io/openshift/ci:ci_fedora_latest: manifest invalid: manifest" is the problem.

Then we can run the cmd with oc-cli in our laptop:

```bash
### get the credentials
$ oc -n ci extract secret/registry-push-credentials-ci-images-mirror --to=- --keys .dockerconfigjson | jq > /tmp/qci.c
### the source and the target are taken from the log
$ oc image mirror --keep-manifest-list --registry-config=/tmp/qci.c --continue-on-error=true --max-per-registry=20  registry.fedoraproject.org/fedora:latest=quay.io/openshift/ci:ci_fedora_latest
```

If it reproduces the same error, mostly, it is caused by a broken source image. In that case, we should
- Fix the source image, e.g., by rebuilding the image.
- Ignore the mirroring otherwise: See [RFE-5363](https://issues.redhat.com/browse/) for example.
