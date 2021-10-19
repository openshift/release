# cert-manager


[AWS Route53](https://cert-manager.io/docs/configuration/acme/dns01/route53/): The credentials of the IAM user `cert-manager` is uploaded to BW item `cert-manager`.

The certificate managed by cert-manager is auto-renewed [when it is 2/3rd of the way through its life](https://github.com/jetstack/cert-manager/issues/2474#issuecomment-619108006).

## installation: yaml-method

```
$ oc config use-context build01
$ oc project cert-manager
### injected the env vars for aws auth
$ oc --as system:admin apply --validate=false -f clusters/build-clusters/01_cluster/cert-manager/_cert-manager.yaml
```

Manual steps: We apply those objects by `applyconfig`. Showing the commands here is only for debugging purpose.

```
$ oc get pod -n cert-manager
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-9b8969d86-dzzhx               1/1     Running   0          19m
cert-manager-cainjector-8545fdf87c-c7cdl   1/1     Running   0          19m
cert-manager-webhook-8c5db9fb6-jrmfx       1/1     Running   0          19m

```

## Customize domain name for registry

DNS setup on GCP project

```
oc --context build01 get svc -n openshift-ingress router-default
NAME             TYPE           CLUSTER-IP       EXTERNAL-IP                                                              PORT(S)                      AGE
router-default   LoadBalancer   172.30.214.155   a574a131d7aed47259e3f519ac0ca099-393633769.us-east-1.elb.amazonaws.com   80:31909/TCP,443:32150/TCP   147d
```

On GCP project `openshift-ci-infra`, Network Services, Cloud DNS: Add a CNAME record for `registry.build01.ci.openshift.org`.

```
### check if it takes effect
$ dig +noall +answer registry.build01.ci.openshift.org | grep CNAME
registry.build01.ci.openshift.org. 277 IN CNAME	a574a131d7aed47259e3f519ac0ca099-393633769.us-east-1.elb.amazonaws.com.
```


Update the Registry Operator with the secret:

```
$ oc --as system:admin --context build01 edit configs.imageregistry.operator.openshift.io cluster
spec:
...
  routes:
  - hostname: registry.build01.ci.openshift.org
    name: public-routes
    secretName: public-route-tls
...
```

Verify:

```
$ podman pull registry.build01.ci.openshift.org/ci/ci-operator:latest
```


