# OpenShift Priv Image Building Jobs
This alert fires when an `openshift-priv` image-building job has a poor 12h success ratio while its corresponding public `openshift` image-building job remains healthy.
The images built from these jobs are often not used, but they do need to be readily available when needed for a CVE fix.
The alert compares paired jobs by suffix:
- Priv: `branch-ci-openshift-priv-<suffix>-images`
- Public: `branch-ci-openshift-<suffix>-images`
This avoids alerting on inherited failures where the public job failed first and the priv job failed as a downstream consequence.

## Useful Links
- [Recent executions on Deck Internal](https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/?job=*-images)
- [Priv image jobs on Deck Internal](https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/?job=branch-ci-openshift-priv-.*-images)
- [Public image jobs on Deck](https://prow.ci.openshift.org/?job=branch-ci-openshift-.*-images)
- [Prometheus Query Browser](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/monitoring/query-browser)

## Triage

### Symptom
Alert message contains:
- The specific failing priv job: `branch-ci-openshift-priv-{{ $labels.job_tail }}`
- The corresponding public job: `branch-ci-openshift-{{ $labels.job_tail }}`
- Direct links to both jobs.

### Resolution
1. Open the linked priv job history and identify the dominant failure mode.
2. Open the linked public counterpart and confirm it is healthy (it should be, by rule design).
3. If priv-only failures persist, reach out to repo owners and/or CI maintainers with both links and failure signatures.
4. If the public job is also failing but this alert fired, treat that as a rule/parsing edge case and open a release-repo PR to refine matching.
