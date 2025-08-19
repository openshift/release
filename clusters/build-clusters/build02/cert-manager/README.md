# cert-manager


[Google CloudDNS](https://cert-manager.io/docs/configuration/acme/dns01/google/): The key file of the service-account `cert-issuer` is uploaded to BW item `cert-issuer`.

The certificate managed by cert-manager is auto-renewed [when it is 2/3rd of the way through its life](https://github.com/jetstack/cert-manager/issues/2474#issuecomment-619108006).

## installation: yaml-method

```
$ oc --context build02 -n cert-manager apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v0.15.1/cert-manager.yaml
```

Manual steps: We apply those objects by `applyconfig`. Showing the commands here is only for debugging purpose.

```
$ oc get pod -n cert-manager
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-9b8969d86-sgn6s               1/1     Running   0          74m
cert-manager-cainjector-8545fdf87c-d8h7q   1/1     Running   0          74m
cert-manager-webhook-8c5db9fb6-c8dx7       1/1     Running   0          74m

### service-account.json is in BW
$ oc --context build02 create -n cert-manager secret generic cert-issuer --from-file=key.json=service-account.json

$ oc apply -f clusters/build-clusters/02_cluster/cert-manager/cert-issuer_clusterissuer.yaml
$ oc get clusterissuer
NAME          READY   AGE
cert-issuer   True    17m

$ oc apply -f clusters/build-clusters/02_cluster/openshift-image-registry/registry-build02_certificate.yaml
$ oc describe CertificateRequest -n openshift-image-registry
...
Events:
  Type    Reason             Age   From          Message
  ----    ------             ----  ----          -------
  Normal  OrderCreated       18m   cert-manager  Created Order resource openshift-image-registry/registry-build02-4027548413-738010858
  Normal  OrderPending       18m   cert-manager  Waiting on certificate issuance from order openshift-image-registry/registry-build02-4027548413-738010858: ""
  Normal  CertificateIssued  15m   cert-manager  Certificate fetched from issuer successfully

###the expected secret is created by cert-manager
$ oc get secret -n openshift-image-registry public-route-tls
NAME               TYPE                DATA   AGE
public-route-tls   kubernetes.io/tls   3      19m

$ site=registry.build02.ci.openshift.org
$ curl --insecure -v "https://${site}" 2>&1 | awk 'BEGIN { cert=0 } /^\* Server certificate:/ { cert=1 } /^\*/ { if (cert) print }'
* Server certificate:
*  subject: CN=registry.build02.ci.openshift.org
*  start date: May 29 01:06:13 2020 GMT
*  expire date: Aug 27 01:06:13 2020 GMT
*  issuer: C=US; O=Let's Encrypt; CN=Let's Encrypt Authority X3
*  SSL certificate verify ok.
* Connection #0 to host registry.build02.ci.openshift.org left intact
* Closing connection 0
```

## installation: operator-hub

Not working yet.

