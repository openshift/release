# openshift-ingress-operator

## CA Certificate for app routes

Openshift 4.2 has doc on [this topic](https://docs.openshift.com/container-platform/4.2/authentication/certificates/replacing-default-ingress-certificate.html).

### Manual steps

#### AWS IAM configuration

[set up aws IAM user](https://github.com/Neilpang/acme.sh/wiki/How-to-use-Amazon-Route53-API): user `openshift-ci-robot` in group `acme` which
    has the policy `acme`.

#### Generate the certificate

Using [acme.sh](https://github.com/Neilpang/acme.sh)

```bash
$ podman run -it --rm neilpang/acme.sh /bin/ash
### BitWarden: aws_ci_infra_openshift-ci-robot
# export  AWS_ACCESS_KEY_ID=xxx
# export  AWS_SECRET_ACCESS_KEY=yyy
# acme.sh --issue --dns dns_aws -d api.build01.ci.devcluster.openshift.com -d '*.apps.build01.ci.devcluster.openshift.com'
...
[Sun Nov 24 18:24:26 UTC 2019] Your cert is in  /acme.sh/*.apps.build01.ci.devcluster.openshift.com/*.apps.build01.ci.devcluster.openshift.com.cer 
[Sun Nov 24 18:24:26 UTC 2019] Your cert key is in  /acme.sh/*.apps.build01.ci.devcluster.openshift.com/*.apps.build01.ci.devcluster.openshift.com.key 
[Sun Nov 24 18:24:26 UTC 2019] The intermediate CA cert is in  /acme.sh/*.apps.build01.ci.devcluster.openshift.com/ca.cer 
[Sun Nov 24 18:24:26 UTC 2019] And the full chain certs is there:  /acme.sh/*.apps.build01.ci.devcluster.openshift.com/fullchain.cer
...
```

> $ oc create secret tls app-cert --cert=path/to/fullchain.cer --key=/path/to/the.key  -n openshift-ingress --dry-run -o yaml | oc apply -f -


> oc patch ingresscontroller.operator default \
     --type=merge -p \
     '{"spec":{"defaultCertificate": {"name": "app-cert"}}}' \
     -n openshift-ingress-operator

Verify if it works:

```
$ curl --insecure -v https://default-route-openshift-image-registry.apps.build01.ci.devcluster.openshift.com 2>&1 | awk 'BEGIN { cert=0 } /^\* Server certificate:/ { cert=1 } /^\*/ { if (cert) print }'
* Server certificate:
*  subject: CN=*.apps.build01.ci.devcluster.openshift.com
*  start date: Nov 24 17:24:24 2019 GMT
*  expire date: Feb 22 17:24:24 2020 GMT
*  issuer: C=US; O=Let's Encrypt; CN=Let's Encrypt Authority X3
*  SSL certificate verify ok.
* Mark bundle as not supporting multiuse
* Added cookie 34727b82525eb26a530629c5bf0ec2f2="3a8eed8be69a9366179c6e84d1dd4f30" for domain default-route-openshift-image-registry.apps.build01.ci.devcluster.openshift.com, path /, expire 0
* Connection #0 to host default-route-openshift-image-registry.apps.build01.ci.devcluster.openshift.com left intact

```

### Auto-reissue certificates

The certificates provided by [letsencrypt](https://letsencrypt.org/2015/11/09/why-90-days.html) are valid for 90 days. Renewal of certificates require the generated folders and files by acme.
For simplicity, we reissue the certificates and apply them in the above secrets.
It is implemented by a periodic job `periodic-acme-cert-issuer-for-build01`.
