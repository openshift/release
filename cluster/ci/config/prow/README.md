## prow setup

Register ProwJobs in the cluster with:
```
oc create -f prow_crd.yaml
```

Ensure the ci namespace exists and create the prow configuration files:
```
oc create ns ci
oc create -f config.yaml -f plugins.yaml -n ci
```

Ensure that the prow-images namespace exists and create all the
build configurations for prow:
```
oc create ns prow-images
oc policy add-role-to-user system:image-puller system:unauthenticated -n prow-images
oc process -f prow_images.yaml | oc create -f -
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
oc process -f openshift/hook.yaml -p HMAC_TOKEN=$(cat hmac-token | base64) -p OAUTH_TOKEN=$(cat oauth-token | base64) | oc create -f -
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

It reuses the oauth token created in the hook template.
```
oc process -f openshift/plank.yaml | oc create -f -
```

### jenkins-operator

`plank` is responsible for the lifecycle of ProwJobs that run Jenkins jobs.
It starts the tests for new ProwJobs, and moves them to completion accordingly.

`jenkins-operator` needs a jenkins token to start jobs in Jenkins and the oauth
token created in the hook template.
```
oc process -f openshift/jenkins-operator.yaml -p JENKINS_TOKEN=$(cat jenkins-token | base64) | oc create -f -
```

### deck

`deck` is the prow frontend. It reuses the jenkins token created in the
jenkins-operator template.
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

## Prow builds

Allow prow to download images from the namespace where the prow builds run.

```
oc policy add-role-to-user system:image-puller system:unauthenticated -n ci
oc policy add-role-to-user system:image-puller system:serviceaccount:ci:hook -n prow-images
oc policy add-role-to-user system:image-puller system:serviceaccount:ci:plank -n prow-images
oc policy add-role-to-user system:image-puller system:serviceaccount:ci:jenkins-operator -n prow-images
oc policy add-role-to-user system:image-puller system:serviceaccount:ci:deck -n prow-images
oc policy add-role-to-user system:image-puller system:serviceaccount:ci:splice -n prow-images
oc policy add-role-to-user system:image-puller system:serviceaccount:ci:sinker -n prow-images
oc policy add-role-to-user system:image-puller system:serviceaccount:ci:horologium -n prow-images
```

## Prow jobs

Build the retester that runs as a periodic prow job and allow it to be pulled
from the "ci" namespace. Create it in the "experiment" namespace, otherwise you
will need to change the prow config.

```
oc new-project experiment
oc process -f ../jobs/commenter.yaml | oc create -f -
oc policy add-role-to-user system:image-puller system:unauthenticated -n experiment
oc project ci
oc policy add-role-to-user system:image-puller system:serviceaccount:ci:default -n experiment
```