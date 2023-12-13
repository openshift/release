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
