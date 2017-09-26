## prow setup

# TODO: Move this at root and repurpose to use our Makefile.

Register ProwJobs in the cluster with:
```
oc create -f prow_crd.yaml
```

Ensure the ci namespace exists and create the prow configuration files:
```
oc new-project ci
oc create cm config --from-file=config=config.yaml -o yaml --dry-run | oc replace -f -
oc create cm plugins --from-file=plugins=plugins.yaml -o yaml --dry-run | oc replace -f -
oc create cm jenkins-proxy --from-file=config=../../../../tools/jenkins-proxy/config.json -o yaml --dry-run | oc replace -f -
```

Create all the build configurations for prow:
```
oc policy add-role-to-user system:image-puller system:unauthenticated -n ci
oc process -f prow_images.yaml | oc apply -f -
oc process -f ../../../../tools/jenkins-proxy/openshift/build.yaml | oc apply -f -
```

Create all required prow secrets:
```
# This is the token used by the jenkins-operator and deck to authenticate with the jenkins-proxy.
oc create secret generic jenkins-token --from-literal=jenkins=${BASIC_AUTH_PASS} -o yaml --dry-run | oc apply -f -
# BASIC_AUTH_PASS is used by the jenkins-proxy for authenticating with https://ci.openshift.redhat.com/jenkins/
# BEARER_TOKEN is used by the jenkins-proxy for authenticating with FILL_ME (--from-literal=bearer=${BEARER_TOKEN})
oc create secret generic jenkins-tokens --from-literal=basic=${BASIC_AUTH_PASS} -o yaml --dry-run | oc apply -f -
# HMAC_TOKEN is used for encrypting Github webhook payloads.
oc create secret generic hmac-token --from-literal=hmac=${HMAC_TOKEN} -o yaml --dry-run | oc apply -f -
# OAUTH_TOKEN is used for manipulating Github PRs/issues (labels, comments, etc.).
oc create secret generic oauth-token --from-literal=oauth=${OAUTH_TOKEN} -o yaml --dry-run | oc apply -f -
```

Start all the prow components:

### hook

`hook` is responsible for listening on Github webhooks and react accordingly
based on the types of the received events. It has a flexible plugin system
and one of its plugins, trigger, is actually responsible for creating PJs
that start tests.

It needs a hmac token for decrypting Github webhooks and an oauth token for
responding to Github events.
```
oc process -f openshift/hook.yaml | oc create -f -
oc process -f openshift/hook_rbac.yaml | oc create -f -
```

#### webhook setup

Create the Github webhook in the repository you want to run tests for.

https://developer.github.com/webhooks/creating/

Use `application/json` for the content type and the hmac-token created
for the secret. Add the URL exposed by the route plus a /hook suffix as
the payload URL, eg. `https://hook-ci.svc.ci.openshift.org/hook`.

### plank

`plank` is responsible for the lifecycle of ProwJobs that run Kubernetes pods.
It starts the tests for new ProwJobs, and moves them to completion accordingly.

It needs an oauth token for updating comments and statuses in Github PRs.
```
oc process -f openshift/plank.yaml | oc create -f -
```

### jenkins-operator

`jenkins-operator` is responsible for the lifecycle of ProwJobs that run Jenkins jobs.
It starts the tests for new ProwJobs, and moves them to completion accordingly.

We run a proxy in front of the Jenkins operator. Deploy it with the following template:
```
oc process -f ../../../../tools/jenkins-proxy/openshift/deploy.yaml | oc create -f -
```

`jenkins-operator` needs a jenkins token to authenticate with the jenkins-proxy in
order to start jobs in Jenkins and an oauth token for updating comments and statuses
in Github PRs.
```
oc process -f openshift/jenkins-operator.yaml | oc create -f -
```

### deck

`deck` is the prow frontend. It needs a jenkins token for authenticating with the
jenkins-proxy in order to get Jenkins logs.
```
oc process -f openshift/deck.yaml | oc create -f -
```

The rest of the components do not depend on any secrets.

### horologium

`horologium` is responsible for creating periodic ProwJobs.
```
oc process -f openshift/horologium.yaml | oc create -f -
```

### splice

`splice` polls the SubmitQueue for mergeable PRs, and creates ProwJobs for batches.
Make sure the options specified in the deployment manifest match your setup
(submit queue location, Github organization, and repository).
```
oc process -f openshift/splice.yaml | oc create -f -
```

### sinker

`sinker` is used for garbage-collecting ProwJobs and Pods.
```
oc process -f openshift/sinker.yaml | oc create -f -
```


## Prow jobs

Build the retester that runs as a periodic prow job and allow it to be pulled
from the "ci" namespace.

```
oc process -f ../jobs/commenter.yaml | oc create -f -
```