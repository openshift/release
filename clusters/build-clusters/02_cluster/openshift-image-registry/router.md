# customize router for image-registry

The default one would be `default-route-openshift-image-registry.apps.build02.gcp.ci.openshift.org` but we like more to use `registry.build02.ci.openshift.org`.

[Steps](https://docs.openshift.com/container-platform/4.4/registry/securing-exposing-registry.html):

* [dns set up](https://cloud.ibm.com/docs/openshift?topic=openshift-openshift_routes): [No official doc yet](https://coreos.slack.com/archives/CCH60A77E/p1588774688400500).

```
oc --context build02 get svc -n openshift-ingress router-default 
NAME                      TYPE           CLUSTER-IP      EXTERNAL-IP    PORT(S)                      AGE
router-default            LoadBalancer   172.30.61.60    34.74.144.21   80:32716/TCP,443:31869/TCP   6d21h
```

GCP project `OpenShift Ci Infra`, Network Service, Cloud DNS: Set up an A record mapping `registry.build02.ci.openshift.org` to `34.74.144.21`.

```
$ dig +noall +answer registry.build02.ci.openshift.org
registry.build02.ci.openshift.org. 245 IN A	34.74.144.21
```
* Configure the Registry Operator:

```
$ oc --as system:admin --context build02 edit configs.imageregistry.operator.openshift.io cluster
spec:
...
  routes:
  - hostname: registry.build02.ci.openshift.org
    name: public-routes
...

$ oc --context build02 get route -n openshift-image-registry
NAME            HOST/PORT                           PATH   SERVICES         PORT    TERMINATION   WILDCARD
public-routes   registry.build02.ci.openshift.org          image-registry   <all>   reencrypt     None

$ podman pull registry.build02.ci.openshift.org/ci/applyconfig --tls-verify=false
```

* Create a secret with your route’s TLS keys via [cert-manager](../cert-manager/readme.md).

* Update the Registry Operator with the secret:

```
$ oc --as system:admin --context build02 edit configs.imageregistry.operator.openshift.io cluster
spec:
...
  routes:
  - hostname: registry.build02.ci.openshift.org
    name: public-routes
    secretName: public-route-tls
...
```

Verify: the above `podman pull` works without `--tls-verify=false`.