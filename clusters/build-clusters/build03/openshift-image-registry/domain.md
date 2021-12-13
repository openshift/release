# Expose registry.build03.ci.openshift.org as registry's domain name

The registry's `defaultRoute` is enabled by default for an OSD cluster, its domain name is

```console
$ oc --context build03 get route -n openshift-image-registry
NAME            HOST/PORT                                                                       PATH   SERVICES         PORT    TERMINATION   WILDCARD
default-route   default-route-openshift-image-registry.apps.build03.ky4t.p1.openshiftapps.com          image-registry   <all>   reencrypt     None
```

And it is used in imagestreams, e.g.:

```console
$ oc --context build03 tag --source=docker quay.io/redhattraining/hello-world-nginx ci/hongkliu-test:latest

$ oc --context build03 get is -n ci --no-headers | head -n 1
hongkliu-test   default-route-openshift-image-registry.apps.build03.ky4t.p1.openshiftapps.com/ci/hongkliu-test   latest   29 seconds ago
```

We want to switch to the domain name `registry.build03.ci.openshift.org` _without_ interrupting the `imagestream`s users.

* Set up the DNS to direct traffic to the cluster's ingress:

```console
$ oc --context build03 get svc -n openshift-ingress router-default
NAME             TYPE           CLUSTER-IP       EXTERNAL-IP                                                               PORT(S)                      AGE
router-default   LoadBalancer   172.30.217.158   a87c3a98bf41141fc849fe5f19bf7868-1812461068.us-east-1.elb.amazonaws.com   80:31587/TCP,443:31887/TCP   6d21h

$ dig @8.8.8.8  +noall +answer registry.build03.ci.openshift.org
registry.build03.ci.openshift.org. 300 IN CNAME	a87c3a98bf41141fc849fe5f19bf7868-1812461068.us-east-1.elb.amazonaws.com.
a87c3a98bf41141fc849fe5f19bf7868-1812461068.us-east-1.elb.amazonaws.com. 60 IN A 54.211.155.231
a87c3a98bf41141fc849fe5f19bf7868-1812461068.us-east-1.elb.amazonaws.com. 60 IN A 18.207.18.102
```

* Generate the certificates and store them in a secret with cert-manager.

* Add the following into `configs.imageregistry.operator.openshift.io/cluster`s `spec`:

```yaml
spec:
  routes:
  - hostname: registry.build03.ci.openshift.org
    name: registry-build03-ci-openshift-org
    secretName: public-route-tls
```

See if it is working

```console
$ oc --context build03 get route -n openshift-image-registry
NAME                                HOST/PORT                                                                       PATH   SERVICES         PORT    TERMINATION   WILDCARD
default-route                       default-route-openshift-image-registry.apps.build03.ky4t.p1.openshiftapps.com          image-registry   <all>   reencrypt     None
registry-build03-ci-openshift-org   registry.build03.ci.openshift.org                                                      image-registry   <all>   reencrypt     None
```

We can pull image, e.g., `podman pull registry.build03.ci.openshift.org/ci/hongkliu-test:latest`.

* Disable the `defaultRoute` and add it as _almost-default-route_:

```yaml
spec:
  defaultRoute: false
  routes:
  - hostname: registry.build03.ci.openshift.org
    name: registry-build03-ci-openshift-org
    secretName: public-route-tls
  - hostname: default-route-openshift-image-registry.apps.build03.ky4t.p1.openshiftapps.com
    name: almost-default-route  
```

* Set up `images.config.openshift.io/cluster`

```yaml
spec:
  externalRegistryHostnames:
  - registry.build03.ci.openshift.org
```

and verify if the new domain is in place:

```console
$ oc --context build03 get is -n ci --no-headers | head -n 1
hongkliu-test   registry.build03.ci.openshift.org/ci/hongkliu-test   latest   20 minutes ago
```

* Remove _almost-default-route_ above and we have only one route for the registry now.

```console
$ oc --context build03 get route -n openshift-image-registry
NAME                                HOST/PORT                           PATH   SERVICES         PORT    TERMINATION   WILDCARD
registry-build03-ci-openshift-org   registry.build03.ci.openshift.org          image-registry   <all>   reencrypt     None

```