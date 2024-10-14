# 02-Cluster

[02-Cluster](https://console-openshift-console.apps.build02.gcp.ci.openshift.org) is an OpenShift-cluster managed by DPTP-team. It is one of the clusters for running Prow job pods.

The secrets have been uploaded to BitWarden item `build_farm_build02`:

* the key file for the service account `ocp-cluster-installer`
* the SSH key pair (`id_rsa` and `id_rsa.pub`)
* install-config.yaml.001 (the one with the desired instance type)
* The auth info for `kubeadmin` and the cert-based kubeconfig file (attachment `b02.admin.cert.kubeconfig`).

## Installation

The gcp project `openshift-ci-build-farm` for installation of this cluster: [gcp console](https://console.cloud.google.com/home/dashboard?project=openshift-ci-build-farm). The project is created by [DPP team](hhttps://issues.redhat.com/browse/DPP-4926).

We created the public zone (base domain for installer) and the service account `ocp-cluster-installer`.
Since this project is dedicated for build farm. We granted the `Owner` role to this account.

Download `install-config.yaml.001` and rename it to `install-config.yaml` and the key file for the GCP SA account and save it to `${HOME}/.gcp/osServiceAccount.json`:

The instance types have been configuration with `install-config.yaml`.
Because of [bz1831838](https://bugzilla.redhat.com/show_bug.cgi?id=1831838), we have to modify the disk size on the _manifests_:

|         | master                   | worker                   |
|---------|--------------------------|--------------------------|
| api.ci  | 150G SSD persistent disk | 300G SSD persistent disk |
| build01 | 150G EBS gp2             | 700G EBS gp2             |
| build02 | 150G SSD persistent disk | 300G SSD persistent disk |


```
$ ./openshift-install create manifests

### modify the disk size 128G to 150G for masters and 300G for workers on those files
$ find . -name "*machines*"
./openshift/99_openshift-cluster-api_worker-machineset-0.yaml
./openshift/99_openshift-cluster-api_worker-machineset-1.yaml
./openshift/99_openshift-cluster-api_master-machines-2.yaml
./openshift/99_openshift-cluster-api_master-machines-0.yaml
./openshift/99_openshift-cluster-api_master-machines-1.yaml
./openshift/99_openshift-cluster-api_worker-machineset-2.yaml
```

Then,

> ./openshift-install create  cluster --log-level=debug

The installation folder is uploaded to gdrive (search for "cluster.openshift4.new"). We need it for destroying the cluster.

### Regenerate `install-config.yaml`

Regenerate `install-config.yaml` in case that the uploaded one is not available. Get the pull secret by 

> oc --context api.ci get secret -n ci cluster-secrets-gcp -o jsonpath='{.data.pull-secret}' | base64 -d

The above pull secret is used to install clusters for e2e tests.

```
./openshift-install create install-config
? SSH Public Key /Users/hongkliu/.ssh/id_rsa_build02.pub
? Platform gcp
? Service Account (absolute path to file or JSON content)
/Users/hongkliu/Downloads/build02.install/openshift-ci-build-farm-64e4ce412ae3.json
INFO Saving the credentials to "/Users/hongkliu/.gcp/osServiceAccount.json"
? Project ID openshift-ci-build-farm
? Region us-east1
INFO Credentials loaded from file "/Users/hongkliu/.gcp/osServiceAccount.json"
? Base Domain gcp.ci.openshift.org
? Cluster Name build02
? Pull Secret
```

Customize [platform.gcp.type](https://docs.openshift.com/container-platform/4.4/installing/installing_gcp/installing-gcp-customizations.html#installation-configuration-parameters_installing-gcp-customizations) in the `install-config.yaml`:

|         | master         | worker         |
|---------|----------------|----------------|
| api.ci  | n1-standard-16 | n1-standard-16 |
| build01 | m5.2xlarge     | m5.4xlarge     |
| build02 | n1-standard-8  | n1-standard-16 |


## Configuration

### openshift-image-registry

#### customize router for image-registry

The default one would be `default-route-openshift-image-registry.apps.build02.gcp.ci.openshift.org` but we like more to use `registry.build02.ci.openshift.org`.

[Steps](https://docs.openshift.com/container-platform/4.4/registry/securing-exposing-registry.html):

* [dns set up](https://cloud.ibm.com/docs/openshift?topic=openshift-openshift_routes): [No official doc yet](https://redhat-internal.slack.com/archives/CCH60A77E/p1588774688400500).

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


### openshift-ingress

#### CA Certificate for app routes

Openshift 4.2 has doc on [this topic](https://docs.openshift.com/container-platform/4.2/authentication/certificates/replacing-default-ingress-certificate.html).

Manual steps: Those `yaml`s are applied automatically by `applyconfig`. We record the steps here for debugging purpose.

[Google CloudDNS](https://cert-manager.io/docs/configuration/acme/dns01/google/): The key file of the service-account `cert-issuer` (in project "openshift-ci-build-farm") is uploaded to BW item `cert-issuer`.


* *Generate the certificate by `cert-manager`

```bash
$ oc --as system:admin apply -f clusters/build-clusters/build02/cert-manager/cert-issuer-ci-build-farm_clusterissuer.yaml
$ oc --as system:admin apply -f clusters/build-clusters/build02/cert-manager//certificate.yaml


$ oc get secret -n openshift-ingress apps-tls
NAME               TYPE                DATA   AGE
apps-tls   kubernetes.io/tls   3      25m
```

* Use the secret in `openshift-ingress-operator`: manual step only for test, see [default_ingresscontroller.yaml](openshift-ingress-operator/default_ingresscontroller.yaml)

```
$ oc --as system:admin patch ingresscontroller.operator default \
     --type=merge -p \
     '{"spec":{"defaultCertificate": {"name": "apps-tls"}}}' \
     -n openshift-ingress-operator

```

Verify if it works:

```
$ site=console-openshift-console.apps.build02.gcp.ci.openshift.org
$ curl --insecure -v "https://${site}" 2>&1 | awk 'BEGIN { cert=0 } /^\* Server certificate:/ { cert=1 } /^\*/ { if (cert) print }'
* Server certificate:
*  subject: CN=*.apps.build02.gcp.ci.openshift.org
*  start date: Jun 15 19:08:40 2020 GMT
*  expire date: Sep 13 19:08:40 2020 GMT
*  issuer: C=US; O=Let's Encrypt; CN=Let's Encrypt Authority X3
*  SSL certificate verify ok.
* Connection #0 to host console-openshift-console.apps.build02.gcp.ci.openshift.org left intact
* Closing connection 0

```

##### Troubleshooting

* [cert-manager/issues/2968](https://github.com/jetstack/cert-manager/issues/2968) is resovled by `hostedZoneName`
which is implemented by [cert-manager/pull/2975](https://github.com/cert-manager/cert-manager/pull/2975).

However, it [turned out](https://redhat-internal.slack.com/archives/CHY2E1BL4/p1675374499210699?thread_ts=1675372628.735039&cid=CHY2E1BL4) we still need the additional arg `--dns01-recursive-nameservers="8.8.8.8:53"` in the deployment of cert-manager.

```bash
oc get deployment -n cert-manager cert-manager -o yaml | yq -r '.spec.template.spec.containers[0].args[]'
--v=2
--cluster-resource-namespace=$(POD_NAMESPACE)
--leader-election-namespace=kube-system
--dns01-recursive-nameservers="8.8.8.8:53"
```

* The selector in ClusterIssuer seems to not work as mentioned in [cert-manager/issues/2968](https://github.com/jetstack/cert-manager/issues/2968):

```
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: cert-issuer-staging
spec:
  acme:
    email: openshift-ci-robot@redhat.com
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: cert-issuer-account-key
    solvers:
    - dns01:
        cloudDNS:
          project: openshift-ci-infra
          serviceAccountSecretRef:
            name: cert-issuer
            key: key.json
        selector:
          matchLabels:
            gcp-project: openshift-ci-infra
    - dns01:
        cloudDNS:
          project: openshift-ci-build-farm
          serviceAccountSecretRef:
            name: cert-issuer
            key: openshift-ci-build-farm-cert-issuer.json
        selector:
          matchLabels:
            gcp-project: openshift-ci-build-farm
```


### openshift-apiserver

#### CA Certificate for the API servers

Openshift 4.2 has doc on [this topic](https://docs.openshift.com/container-platform/4.2/authentication/certificates/api-server.html).

Manual steps: Those `yaml`s are applied automatically by `applyconfig`. We record the steps here for debugging purpose.

* Generate the certificate by cert-manager:

```
$ oc --as system:admin --context build02 apply -f clusters/build-clusters/build02/openshift-apiserver/certificate.yaml
```

* Use the certificates in API server:

```
oc --as system:admin patch apiserver cluster --type=merge -p '{"spec":{"servingCerts": {"namedCertificates": [{"names": ["api.build02.gcp.ci.openshift.org"], "servingCertificate": {"name": "apiserver-tls"}}]}}}'
```

Verify if it works:

```
$ site=api.build02.gcp.ci.openshift.org:6443
$ curl --insecure -v https://${site} 2>&1 | awk 'BEGIN { cert=0 } /^\* Server certificate:/ { cert=1 } /^\*/ { if (cert) print }'
* Server certificate:
*  subject: CN=api.build02.gcp.ci.openshift.org
*  start date: Jun 16 11:46:39 2020 GMT
*  expire date: Sep 14 11:46:39 2020 GMT
*  issuer: C=US; O=Let's Encrypt; CN=Let's Encrypt Authority X3
*  SSL certificate verify ok.
* Using HTTP2, server supports multi-use
* Connection state changed (HTTP/2 confirmed)
* Copying HTTP/2 data in stream buffer to connection buffer after upgrade: len=0
* Using Stream ID: 1 (easy handle 0x7ffd3780aa00)
* Connection state changed (MAX_CONCURRENT_STREAMS == 2000)!
* Connection #0 to host api.build02.gcp.ci.openshift.org left intact

```

## Upgrade the cluster

Unlike `build01` which has an automated job to do the upgrades, we upgrade `build02` manually.
This is to keep the possibility of failover: in case of `build01` is upgraded to a version with issues,
we still have a working `build02` in our build farm.
