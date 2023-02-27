# OpenShift Priv Image Building Jobs
This alert fires when a high number of failures are occurring in `openshift-priv` image-building jobs.
The images built from these jobs are often not used, but they do need to be readily available when needed for a CVE fix.
As this alert is the result of an aggregate of job statuses from all of the repos in the `openshift-priv` org, individual failing job logs will need to be examined, and may not be failing due to the same reason.

## Useful Links
- [Recent executions on Deck Internal](https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/?job=*-images)
- [Prometheus Success Rate Graph](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/monitoring/query-browser?query0=%28sum%28rate%28prowjob_state_transitions%7Bjob%3D%22prow-controller-manager%22%2Cjob_name%3D%7E%22.*-images%22%2Corg%3D%22openshift-priv%22%2Cstate%3D%22success%22%7D%5B12h%5D%29%29%2Fsum%28rate%28prowjob_state_transitions%7Bjob%3D%22prow-controller-manager%22%2Cjob_name%3D%7E%22.*-images%22%2Corg%3D%22openshift-priv%22%2Cstate%3D%7E%22success%7Cfailure%7Caborted%22%7D%5B12h%5D%29%29%29)

## Corresponding public (`openshift` org) image-building job is also failing

### Symptom
It is important to check the corresponding public image building job on [deck](https://prow.ci.openshift.org/?job=*-images) for failures.

### Resolution
If it is also failing: reach out to the owner(s) of the repo, explain the failure, and ask them to fix it or disable the promotion.
