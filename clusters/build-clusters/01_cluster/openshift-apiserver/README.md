# openshift-ingress-operator

## CA Certificate for the API servers

Openshift 4.2 has doc on [this topic](https://docs.openshift.com/container-platform/4.2/authentication/certificates/api-server.html).

```bash
### by default, a self-signed certificate is used
$ curl --insecure -v https://api.build01.ci.devcluster.openshift.com:6443 2>&1 | awk 'BEGIN { cert=0 } /^\* Server certificate:/ { cert=1 } /^\*/ { if (cert) print }'
* Server certificate:
*  subject: CN=api.build01.ci.devcluster.openshift.com
*  start date: Nov 30 20:40:37 2019 GMT
*  expire date: Dec 30 20:40:38 2019 GMT
*  issuer: OU=openshift; CN=kube-apiserver-lb-signer
*  SSL certificate verify result: self signed certificate in certificate chain (19), continuing anyway.
* Using HTTP2, server supports multi-use
* Connection state changed (HTTP/2 confirmed)
* Copying HTTP/2 data in stream buffer to connection buffer after upgrade: len=0
* Using Stream ID: 1 (easy handle 0x55ae013e3180)
* Connection state changed (MAX_CONCURRENT_STREAMS == 2000)!
* Connection #0 to host api.build01.ci.devcluster.openshift.com left intact


```

### Manual steps

#### AWS IAM configuration

[set up aws IAM user](https://cert-manager.io/docs/configuration/acme/dns01/route53/#set-up-an-iam-role): user `cert-manager` in group `cert-manager` which
    has the policy `cert-manager`.

#### Generate the certificate

Use `cert-manager` to generate the secret containing the certificates:

```bash
$ oc  --context build01 get secret -n openshift-config apiserver-build01-tls
NAME                    TYPE                DATA   AGE
apiserver-build01-tls   kubernetes.io/tls   3      6d21h
```

Use the secret in apiserver's config:

> oc patch apiserver cluster --type=merge -p '{"spec":{"servingCerts": {"namedCertificates": [{"names": ["api.build01.ci.devcluster.openshift.com"], "servingCertificate": {"name": "apiserver-build01-tls"}}]}}}' 

Verify if it works:

```
$ curl --insecure -v https://api.build01.ci.devcluster.openshift.com:6443 2>&1 | awk 'BEGIN { cert=0 } /^\* Server certificate:/ { cert=1 } /^\*/ { if (cert) print }'
* Server certificate:
*  subject: CN=api.build01.ci.devcluster.openshift.com
*  start date: Jun 30 13:17:41 2020 GMT
*  expire date: Sep 28 13:17:41 2020 GMT
*  issuer: C=US; O=Let's Encrypt; CN=Let's Encrypt Authority X3
*  SSL certificate verify ok.
* Connection state changed (HTTP/2 confirmed)
* Copying HTTP/2 data in stream buffer to connection buffer after upgrade: len=0
* Using Stream ID: 1 (easy handle 0x7f8c80808200)
* Connection state changed (MAX_CONCURRENT_STREAMS == 2000)!
* Connection #0 to host api.build01.ci.devcluster.openshift.com left intact

```

Note that we no longer need `--insecure-skip-tls-verify=true` upon `oc login --token=token --server=https://api.build01.ci.devcluster.openshift.com:6443`.
