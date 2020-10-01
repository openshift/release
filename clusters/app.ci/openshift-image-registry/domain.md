# Expose registry.ci.openshift.org as registry's domain name

After the registry's `defaultRoute` is enabled, its domain name is

```console
$ oc --context app.ci get route -n openshift-image-registry
NAME            HOST/PORT                                                                  PATH   SERVICES         PORT    TERMINATION   WILDCARD
default-route   default-route-openshift-image-registry.apps.ci.l2s4.p1.openshiftapps.com          image-registry   <all>   reencrypt     None
```

And it is used in imagestreams, e.g.:

```console
$ oc --context app.ci get is -n ci --no-headers | head -n 1
alpine                            default-route-openshift-image-registry.apps.ci.l2s4.p1.openshiftapps.com/ci/alpine                            latest,3.10                                                    2 months ago
```

We want to switch to the domain name `registry.ci.openshift.org` _without_ interrupting the `imagestream`s users.

* Set up the DNS to direct traffic to the cluster's ingress:

```console
$ dig @8.8.8.8  +noall +answer registry.ci.openshift.org
registry.ci.openshift.org. 299	IN	CNAME	a09c911550acb4a288874373c56fa189-479558196.us-east-1.elb.amazonaws.com.
a09c911550acb4a288874373c56fa189-479558196.us-east-1.elb.amazonaws.com.	59 IN A	34.200.56.176
a09c911550acb4a288874373c56fa189-479558196.us-east-1.elb.amazonaws.com.	59 IN A	34.196.28.27
```

* Generate the certificates and store them in a secret: [registry-ci-openshift-org_certificate.yaml](../cert-manager/registry-ci-openshift-org_certificate.yaml)

* Add the following into `configs.imageregistry.operator.openshift.io/cluster`s `spec`:

```yaml
spec:
  routes:
  - hostname: registry.ci.openshift.org
    name: registry-ci-openshift-org
    secretName: registry-ci-openshift-org-tls
```

See if it is working

```console
$ oc --context app.ci get route -n openshift-image-registry
NAME                        HOST/PORT                                                                  PATH   SERVICES         PORT    TERMINATION   WILDCARD
default-route               default-route-openshift-image-registry.apps.ci.l2s4.p1.openshiftapps.com          image-registry   <all>   reencrypt     None
registry-ci-openshift-org   registry.ci.openshift.org                                                         image-registry   <all>   reencrypt     None
```

We can pull image, e.g., `podman pull registry.ci.openshift.org/ci/applyconfig:latest`.

* Disable the `defaultRoute` and add it as _almost-default-route_:

```yaml
spec:
  defaultRoute: false
  routes:
  - hostname: registry.ci.openshift.org
    name: registry-ci-openshift-org
    secretName: registry-ci-openshift-org-tls
  - hostname: default-route-openshift-image-registry.apps.ci.l2s4.p1.openshiftapps.com
    name: almost-default-route  
```

* Set up `images.config.openshift.io/cluster`

```yaml
spec:
  externalRegistryHostnames:
  - registry.ci.openshift.org
```

and verify if the new domain is in place:

```console
$ oc --context app.ci get is -n ci --no-headers | head -n 1
alpine                            registry.ci.openshift.org/ci/alpine                            latest,3.10                                                    2 months ago
```

* Remove _almost-default-route_ above and we have only one route for the registry now.

```console
$ oc --context app.ci get route -n openshift-image-registry
NAME                        HOST/PORT                   PATH   SERVICES         PORT    TERMINATION   WILDCARD
registry-ci-openshift-org   registry.ci.openshift.org          image-registry   <all>   reencrypt     None

```