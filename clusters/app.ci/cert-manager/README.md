# cert-manager


[Google CloudDNS](https://cert-manager.io/docs/configuration/acme/dns01/google/): The key file of the service-account `cert-issuer` is uploaded to BW item `cert-issuer`.

The certificate managed by cert-manager is auto-renewed [when it is 2/3rd of the way through its life](https://github.com/jetstack/cert-manager/issues/2474#issuecomment-619108006).

## DNS set up

```
oc --context app.ci get svc -n openshift-ingress router-default
NAME             TYPE           CLUSTER-IP      EXTERNAL-IP                                                              PORT(S)                      AGE
router-default   LoadBalancer   172.30.208.88   a09c911550acb4a288874373c56fa189-479558196.us-east-1.elb.amazonaws.com   80:32000/TCP,443:32600/TCP   68d
```

On GCP project `openshift-ci-infra`, Network Services, Cloud DNS: Add a CNAME record for `steps.ci.openshift.org`.

```
### check if it takes effect
$ dig +noall +answer  steps.ci.openshift.org | grep CNAME
steps.ci.openshift.org.	241	IN	CNAME	a09c911550acb4a288874373c56fa189-479558196.us-east-1.elb.amazonaws.com.
```

## installation: yaml-method

```
$ oc config user-context app.ci
$ oc project cert-manager
### replace kube-system with cert-manager-system
$ oc --as system:admin apply --validate=false -f clusters/app.ci/cert-manager/_cert-manager.yaml
```

Manual steps: We apply those objects by `applyconfig`. Showing the commands here is only for debugging purpose.

```
$ oc get pod -n cert-manager
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-6bf5bdd57f-8mvk8              1/1     Running   0          28s
cert-manager-cainjector-78f585775b-zl29f   1/1     Running   0          28s
cert-manager-webhook-8c5db9fb6-48msx       1/1     Running   0          28s

### service-account.json is in BW
$ oc --context build02 create -n cert-manager secret generic cert-issuer --from-file=key.json=service-account.json

$ oc apply -f clusters/app.ci/cert-manager/cert-issuer-staging_clusterissuer.yaml
$ oc --as system:admin apply -f clusters/app.ci/cert-manager/cert-issuer_clusterissuer.yaml
$ oc get clusterissuer                                                                      
NAME                  READY   AGE
cert-issuer           True    2s
cert-issuer-staging   True    20s

### create the ingress
$ oc --as system:admin apply -f clusters/app.ci/cert-manager/steps_ingress.yaml

$ oc describe CertificateRequest -n ci
...
  Normal  CertificateIssued  15m   cert-manager  Certificate fetched from issuer successfully

###the expected secret is created by cert-manager
$ oc get secret -n ci prow-tls
NAME       TYPE                DATA   AGE
prow-tls   kubernetes.io/tls   3      9m33s

$ site=steps.ci.openshift.org
$ curl --insecure -v "https://${site}" 2>&1 | awk 'BEGIN { cert=0 } /^\* Server certificate:/ { cert=1 } /^\*/ { if (cert) print }'
* Server certificate:
*  subject: CN=steps.ci.openshift.org
*  start date: Jun 23 19:50:18 2020 GMT
*  expire date: Sep 21 19:50:18 2020 GMT
*  issuer: C=US; O=Let's Encrypt; CN=Let's Encrypt Authority X3
*  SSL certificate verify ok.
* Connection #0 to host steps.ci.openshift.org left intact
* Closing connection 0
```
