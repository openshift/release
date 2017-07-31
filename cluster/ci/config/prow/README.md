## prow setup

We are going to run the prow components on GKE for the 3.6 timeframe since
we don't support ThirdPartyResources in Openshift. Once we release 3.7, with
support for CustomResourceDefinitions (the new TPR), we will be able to move
prow on top of Openshift.

With that limitation in mind, we concluded to terminate https connections from
Github on Openshift, which means that the hook and deck services need to be
created and exposed as routes in our CI cluster. As a backend to those services
we will run two nginx instances, one for each route, that will proxy to GKE.
We could possibly run a single nginx instance but that would require switching
the labels in the services to use different label keys and also switch them back
to point to separate instances once we remove the proxies in favor of the actual
pods (3.7).

In an Openshift cluster, process the template that creates the proxies. Make
sure the template contains the correct GKE IP.
```
oc process -f proxy/proxies.yaml | oc create -f -
```

## GKE k8s cluster turn-up

Set up CLUSTER to the desired cluster name (can be whatever you want), ZONE to a [valid GCE zone](https://cloud.google.com/compute/docs/regions-zones/regions-zones),
and PROJECT to *openshift-gce-devel*. Adding the empty label `preserve` protects the GCE instances this command will create by excluding it from our [long-running instance report and our instance pruning script](https://github.com/openshift/li/blob/9618207bcf5014071354ce591c4e90b04056b93a/build/lib/openshift/gce.rb#L241-L245). This should only be added for our production environment.

Then, create a cluster in GKE:
```
gcloud container clusters create $CLUSTER \
       --machine-type n1-standard-4 \
       --num-nodes 2 \
       --scopes "https://www.googleapis.com/auth/compute","https://www.googleapis.com/auth/devstorage.full_control","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management" \
       --network "default" \
       --labels=preserve="" \
       --project $PROJECT \
       --zone $ZONE \
       --quiet
```

Get the cluster kubeconfig:
```
gcloud container clusters get-credentials $CLUSTER
```

Create the Ingress resource that will be managed by the GKE load balancer:
```
oc create -f gke/ingress.yaml
```

As per [Step 5, Option 2](https://cloud.google.com/container-engine/docs/tutorials/http-balancer),
we need to reserve a static IP that will be used by our Ingress resource. Optional for testing.
```
gcloud compute addresses create prow --global
```

Register ProwJobs in the cluster with:
```
oc create -f gke/prow_job.yaml
```

## hook turn-up

hook is responsible for listening on Github webhooks and react accordingly
based on the types of the received events. It has a flexible plugin system
and one of its plugins, trigger, is actually responsible for creating PJs
that start tests.

1. Create the secrets that will allow prow to talk to GitHub. The `hmac-token`
is the token that you set on GitHub webhooks. Generate one[1], store it as
hmac-token, and create a secret out of it.
```
oc create secret generic hmac-token --from-file=hmac=hmac-token
```
The `oauth-token` is an OAuth2 token that has read and write access to the bot account.
Make sure that this and the SubmitQueue bots are different.
```
oc create secret generic oauth-token --from-file=oauth=oauth-token --from-literal=github-bot=openshift-ci-robot
```
[1] https://gist.github.com/kargakis/ef003a13c0e1f708836b60100f6e1aef

1. Create the prow and plugin configurations
```
oc create -f config.yaml -f plugins.yaml
```

While the plugins configuration is used specifically by hook, the prow config
file is used by all prow components.

1. Create the hook service and deployment.
```
oc create -f gke/hook.yaml
```

1. Create the Github webhook in the repository you want to run tests for.

https://developer.github.com/webhooks/creating/

Use `application/json` for the content type and the hmac-token created in
the first step for the secret. Add the URL exposed by the route plus a
/hook suffix as the payload URL. Eg. `https://hook-ci.svc.ci.openshift.org/hook`.

## plank turn-up

plank is responsible for the lifecycle of ProwJobs. It starts the tests for
new ProwJobs, and moves them to completion accordingly.

plank needs access to Jenkins so that it can start Jenkins jobs. It needs the
address of a Jenkins server, a Jenkins username, and API token. Retrieve the
API token from the Jenkins console (http://jenkins-address/jenkins/user/<username>/configure)
and store it in a file named jenkins_token. Then, create a secret that will
be mounted in the plank deployment:
```
oc create secret generic jenkins-token --from-file=jenkins=jenkins_token
```
Create a ConfigMap named jenkins-config that will hold the Jenkins address
and username to be used by plank. Make sure the keys stay as "jenkins_address"
and "jenkins_user":
```
oc create cm jenkins-config --from-literal=jenkins_address=https://ci.openshift.redhat.com/jenkins/job/ --from-literal=jenkins_user=openshift-ci-robot
```
plank also needs a Github Oauth token for updating PR statuses based on the
outcome of ProwJobs. For now, I reuse the same token used by hook. Eventually,
we should probably have a separate token per deployment.
```
oc create -f gke/plank.yaml
```

## deck turn-up

deck needs Jenkins credentials for returning logs from Jenkins. The same ConfigMap
and secret that plank uses, will be reused here.

Create the deck service and deployment.
```
oc create -f gke/deck.yaml
```

## splice turn-up

splice polls the SubmitQueue for mergeable PRs, and creates ProwJobs for batches.
Make sure the options specified in the deployment manifest match your setup
(submit queue location, Github organization, and repository).
```
oc create -f gke/splice.yaml
```

## sinker turn-up

sinker is used for garbage-collecting ProwJobs and Pods.
```
oc create -f gke/sinker.yaml
```

## Cleanup

Delete the cluster with:
```
gcloud container clusters delete $CLUSTER
```
If you have setup a static IP, it needs to be manually cleaned up.
