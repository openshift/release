# openshift-ingress-operator

## CA Certificate for app routes

Openshift 4.2 has doc on [this topic](https://docs.openshift.com/container-platform/4.2/authentication/certificates/replacing-default-ingress-certificate.html).

### Manual steps

#### AWS IAM configuration

[set up aws IAM user](https://cert-manager.io/docs/configuration/acme/dns01/route53/#set-up-an-iam-role): user `cert-manager` in group `cert-manager` which
    has the policy `cert-manager`.

#### Generate the certificate

Use `cert-manager` to generate the secret containing the certificates:

```bash
$ oc  --context build01 get secret -n openshift-ingress apps-build01-tls
NAME               TYPE                DATA   AGE
apps-build01-tls   kubernetes.io/tls   3      6d23h
```

Use the secret in apiserver's config:

> oc patch ingresscontroller.operator default \
     --type=merge -p \
     '{"spec":{"defaultCertificate": {"name": "apps-build01-tls"}}}' \
     -n openshift-ingress-operator

Verify if it works:

```
$ curl --insecure -v https://default-route-openshift-image-registry.apps.build01.ci.devcluster.openshift.com 2>&1 | awk 'BEGIN { cert=0 } /^\* Server certificate:/ { cert=1 } /^\*/ { if (cert) print }'
* Server certificate:
*  subject: CN=*.apps.build01.ci.devcluster.openshift.com
*  start date: Jun 30 13:17:41 2020 GMT
*  expire date: Sep 28 13:17:41 2020 GMT
*  issuer: C=US; O=Let's Encrypt; CN=Let's Encrypt Authority X3
*  SSL certificate verify ok.
* Connection #0 to host default-route-openshift-image-registry.apps.build01.ci.devcluster.openshift.com left intact

```
