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

[set up aws IAM user](https://github.com/Neilpang/acme.sh/wiki/How-to-use-Amazon-Route53-API): user `openshift-ci-robot` in group `acme` which
    has the policy `acme`.

#### Generate the certificate

Using [acme.sh](https://github.com/Neilpang/acme.sh)

```bash
$ podman run -it --rm neilpang/acme.sh /bin/ash
### BitWarden: aws_ci_infra_openshift-ci-robot
# export  AWS_ACCESS_KEY_ID=xxx
# export  AWS_SECRET_ACCESS_KEY=yyy
# acme.sh --issue --dns dns_aws -d api.build01.ci.devcluster.openshift.com
...
```

> $ oc create secret tls apiserver-cert --cert=path/to/fullchain.cer --key=/path/to/the.key  -n openshift-config --dry-run -o yaml | oc apply -f -


> oc patch apiserver cluster --type=merge -p '{"spec":{"servingCerts": {"namedCertificates": [{"names": ["api.build01.ci.devcluster.openshift.com"], "servingCertificate": {"name": "apiserver-cert"}}]}}}' 

Verify if it works:

```
$ curl --insecure -v https://api.build01.ci.devcluster.openshift.com:6443 2>&1 | awk 'BEGIN { cert=0 } /^\* Server certificate:/ { cert=1 } /^\*/ { if (cert) print }'
* Server certificate:
*  subject: CN=api.build01.ci.devcluster.openshift.com
*  start date: Dec  9 18:28:27 2019 GMT
*  expire date: Mar  8 18:28:27 2020 GMT
*  issuer: C=US; O=Let's Encrypt; CN=Let's Encrypt Authority X3
*  SSL certificate verify ok.
* Using HTTP2, server supports multi-use
* Connection state changed (HTTP/2 confirmed)
* Copying HTTP/2 data in stream buffer to connection buffer after upgrade: len=0
* Using Stream ID: 1 (easy handle 0x55904adc9180)
* Connection state changed (MAX_CONCURRENT_STREAMS == 2000)!
* Connection #0 to host api.build01.ci.devcluster.openshift.com left intact

```

Note that we no longer need `--insecure-skip-tls-verify=true` upon `oc login --token=token --server=https://api.build01.ci.devcluster.openshift.com:6443`.

### Auto-reissue certificates

The certificates provided by [letsencrypt](https://letsencrypt.org/2015/11/09/why-90-days.html) are valid for 90 days. Renewal of certificates require the generated folders and files by acme.
For simplicity, we reissue the certificates and apply them in the above secrets.
It is implemented by a periodic job `periodic-acme-cert-issuer-for-build01`.
