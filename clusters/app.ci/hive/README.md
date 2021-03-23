# Hive

[Hive](https://github.com/openshift/hive) is used as ClusterPool API to manage clusters for CI tests.

## Deploy hive-operator via OLM
See [Hive doc](https://github.com/openshift/hive/blob/master/docs/install.md).

* Note that before installing Hive, become a cluster admin (and revoke it afterwards).

* Create `hive` project.

```console
$ oc apply -f clusters/app.ci/hive/hive_ns.yaml
```

* After installation steps are completed via OLM UI, `hive-operator` pod is running.

```console
$ oc get pod -n hive
NAME                            READY   STATUS    RESTARTS   AGE
hive-operator-8848d9948-q7mjq   1/1     Running   0          2m52s
```

##  Deploy Hive

Create a `HiveConfig` to create a hive deployment.

```console
$ oc apply -f clusters/app.ci/hive/hive_hiveconfig.yaml
hiveconfig.hive.openshift.io/hive created
```

Check if the relevant pods are running.

```console
oc get pod -n hive
NAME                                READY   STATUS    RESTARTS   AGE
hive-clustersync-0                  1/1     Running   0          2m16s
hive-controllers-578c8cdb45-5h94g   1/1     Running   0          2m16s
hive-operator-8848d9948-q7mjq       1/1     Running   0          13m
hiveadmission-9f7df866b-lbcmp       1/1     Running   0          2m16s
hiveadmission-9f7df866b-zb98l       1/1     Running   0          2m16s
```

## Configure DNS for Hive
### AWS Route53
base domain: `hive.aws.ci.openshift.org`. We only need set up this once for all clusters on AWS with `hive.aws.ci.openshift.org` as base domain.

Account: https://openshift-ci.signin.aws.amazon.com/console

This account has been used to create ephemeral clusters via installer directly for CI jobs.

* route53 console: Create a zone `hive.aws.ci.openshift.org`. We can see the list of name servers in the NS record after creation.
* cloud DNS at GCP (`project=openshift-ci-infra`): Under zone `origin-ci-ocp-public-dns` (which manages domain `ci.openshift.org`), create a NS record for `hive.aws.ci.openshift.org` using the the list of name servers from route53 console above.

```console
$ dig hive.aws.ci.openshift.org
; <<>> DiG 9.10.6 <<>> hive.aws.ci.openshift.org
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 28094
;; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 1, ADDITIONAL: 1
;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 512
;; QUESTION SECTION:
;hive.aws.ci.openshift.org.	IN	A
;; AUTHORITY SECTION:
hive.aws.ci.openshift.org. 899	IN	SOA	ns-853.awsdns-42.net. awsdns-hostmaster.amazon.com. 1 7200 900 1209600 86400
;; Query time: 79 msec
;; SERVER: 8.8.8.8#53(8.8.8.8)
;; WHEN: Wed Mar 17 10:36:12 EDT 2021
;; MSG SIZE  rcvd: 138
```

## Deploy a cluster via Hive

### SSH key
Create `secret/jenkins-ci-iam-ssh-key` in `namespace/hive` containing `ssh-privatekey` and `ssh-publickey` using BitWarden item `jenkins-ci-iam`.
   
### Pull Secret

Create `secret/test01-pull-secret` in `namespace/hive` which will be used by `ClusterDeployment` later.

```console
### reuse the existing pull secret, we use this pull-secret to generate the install-config above.
$ oc --context build01 extract secret/cluster-secrets-aws -n ci --keys=pull-secret --to=- > ./.dockerconfigjson
$ oc create secret generic test01-pull-secret --from-file=.dockerconfigjson=./.dockerconfigjson --type=kubernetes.io/dockerconfigjson -n hive
```

### Deploy a cluster on AWS

#### Cloud credentials

Create `secret/jenkins-ci-iam-aws-creds` in `namespace/hive` containing `aws_access_key_id` and `aws_secret_access_key` using BitWarden item `jenkins-ci-iam`.

#### Create install-config

We can use `openshift-install create install-config` to create an install-config and store it in a secret.

```console
$ oc -n hive create secret generic test01-install-config --from-file=install-config.yaml=./install-config.yaml
```

#### Create ClusterDeployment
`.spec.provisioning.releaseImage` specifies OpenShift version to install.

```yaml
# test01.clusterdeployment.yaml
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: test01
  namespace: hive
spec:
  baseDomain: hive.aws.ci.openshift.org
  clusterName: test01
  platform:
    aws:
      credentialsSecretRef:
        name: jenkins-ci-iam-aws-creds
      region: us-east-1
  provisioning:
    releaseImage: quay.io/openshift-release-dev/ocp-release:4.6.0-x86_64
    installConfigSecretRef:
      name: test01-install-config
    sshPrivateKeySecretRef:
      name: jenkins-ci-iam-ssh-key
  pullSecretRef:
    name: test01-pull-secret 
```

Create `ClusterDeployment/test01` above will trigger hive to start installing the cluster.

```console
$ oc apply -f test01.clusterdeployment.yaml  --as system:admin
clusterdeployment.hive.openshift.io/test01 created
```

The installation log is

```console
$ oc logs -n hive test01-0-j5dx7-provision-2jcbz -c hive -f
```

Get admin's kubeconfig:

```console
$ oc get cd -n hive test01 -o yaml | yq -r .spec.clusterMetadata.adminKubeconfigSecretRef.name
test01-0-j5dx7-admin-kubeconfig

$ oc -n hive extract secret/test01-0-j5dx7-admin-kubeconfig --keys=kubeconfig --to=- > test01.admin.kubeconfig

$ oc --kubeconfig test01.admin.kubeconfig get node
NAME                           STATUS   ROLES    AGE   VERSION
ip-10-0-128-147.ec2.internal   Ready    worker   30m   v1.19.0+d59ce34
ip-10-0-128-194.ec2.internal   Ready    master   40m   v1.19.0+d59ce34
ip-10-0-153-90.ec2.internal    Ready    worker   31m   v1.19.0+d59ce34
ip-10-0-158-200.ec2.internal   Ready    master   40m   v1.19.0+d59ce34
ip-10-0-160-221.ec2.internal   Ready    worker   31m   v1.19.0+d59ce34
ip-10-0-167-161.ec2.internal   Ready    master   40m   v1.19.0+d59ce34
```

## Destroy a cluster via Hive

```console
$ oc -n hive delete clusterdeployment test01 --wait=false --as system:admin
clusterdeployment.hive.openshift.io "test01" deleted
```

Check logs:

```console
$ oc logs -n hive test01-uninstall-h8qhh
```

## ClusterPool

```yaml
# openshift-v4.6.0-ClusterImageSet.yaml
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: openshift-v4.6.0
spec:
  releaseImage: quay.io/openshift-release-dev/ocp-release:4.6.0-x86_64
```

```console
$ oc apply -f openshift-v4.6.0-ClusterImageSet.yaml
```

Create a cluster pool.

```yaml
# ci-openshift-46-aws-us-east-1-ClusterPool.yaml
apiVersion: hive.openshift.io/v1
kind: ClusterPool
metadata:
  name: ci-openshift-46-aws-us-east-1
  namespace: hive
spec:
  baseDomain: hive.aws.ci.openshift.org
  imageSetRef:
    name: openshift-v4.6.0
  installConfigSecretTemplateRef: 
    name: test01-install-config
  skipMachinePools: true
  platform:
    aws:
      credentialsSecretRef:
        name: jenkins-ci-iam-aws-creds
      region: us-east-1
  pullSecretRef:
    name: test01-pull-secret
  size: 1
```

```console
$ oc apply -f ci-openshift-46-aws-us-east-1-ClusterPool.yaml --as system:admin
```

`hive` will maintain the pool with the desired size.

```console
$ oc logs -n hive hive-controllers-578c8cdb45-5h94g | grep "Successfully Reconciled" | tail -1
time="2021-03-18T20:32:04.527Z" level=debug msg="Successfully Reconciled" _name=controller controller=clusterprovision-controller name=ci-openshift-46-aws-us-east-1-ccxp4-0-gpjsf namespace=ci-openshift-46-aws-us-east-1-ccxp4

$ oc get cd -n ci-openshift-46-aws-us-east-1-ccxp4
NAME                                  PLATFORM   REGION      CLUSTERTYPE   INSTALLED   INFRAID                       VERSION   POWERSTATE   AGE
ci-openshift-46-aws-us-east-1-ccxp4   aws        us-east-1                 false       ci-openshift-46-aws-u-kth2h                          6m6s

$ oc get pod -n ci-openshift-46-aws-us-east-1-ccxp4
NAME                                                          READY   STATUS     RESTARTS   AGE
ci-openshift-46-aws-us-east-1-ccxp4-0-gpjsf-provision-hc96n   1/3     NotReady   0          4m53s

# it is being installed
$ oc logs -n ci-openshift-46-aws-us-east-1-ccxp4 ci-openshift-46-aws-us-east-1-ccxp4-0-gpjsf-provision-hc96n -c hive -f

# the cluster hibernates if not claimed (VMs were stopped)
$ oc get cd -n ci-openshift-46-aws-us-east-1-ccxp4
NAME                                  PLATFORM   REGION      CLUSTERTYPE   INSTALLED   INFRAID                       VERSION   POWERSTATE    AGE
ci-openshift-46-aws-us-east-1-ccxp4   aws        us-east-1                 true        ci-openshift-46-aws-u-kth2h   4.6.0     Hibernating   5h9m
```

Claim a cluster:

```yaml
# cluster46-ClusterClaim.yaml
apiVersion: hive.openshift.io/v1
kind: ClusterClaim
metadata:
  name: cluster46
  namespace: hive
spec:
  clusterPoolName: ci-openshift-46-aws-us-east-1
  lifetime: 8h # terminated after 8h
```

```console
$ oc apply -f cluster46-ClusterClaim.yaml --as system:admin

$ oc get clusterclaim -n hive
NAME        POOL                            PENDING          CLUSTERNAMESPACE                      CLUSTERRUNNING
cluster46   ci-openshift-46-aws-us-east-1   ClusterClaimed   ci-openshift-46-aws-us-east-1-ccxp4   Resuming

$ oc get clusterclaim -n hive
NAME        POOL                            PENDING          CLUSTERNAMESPACE                      CLUSTERRUNNING
cluster46   ci-openshift-46-aws-us-east-1   ClusterClaimed   ci-openshift-46-aws-us-east-1-ccxp4   Running
```

When a cluster in a cluster pool is claimed, it is removed from the pool. Hive creates a new cluster to maintain the pool size.

When the claimed cluster is `Running`, we can use the cluster.

```console
$ oc get cd -n ci-openshift-46-aws-us-east-1-ccxp4 ci-openshift-46-aws-us-east-1-ccxp4 -o yaml | yq -r .spec.clusterMetadata.adminKubeconfigSecretRef.name
ci-openshift-46-aws-us-east-1-ccxp4-0-gpjsf-admin-kubeconfig

$ oc -n ci-openshift-46-aws-us-east-1-ccxp4 extract secret/ci-openshift-46-aws-us-east-1-ccxp4-0-gpjsf-admin-kubeconfig --keys=kubeconfig --to=- > cluster46.admin.kubeconfig

$ oc --kubeconfig cluster46.admin.kubeconfig get node
NAME                           STATUS   ROLES    AGE     VERSION
ip-10-0-140-245.ec2.internal   Ready    worker   5h4m    v1.19.0+d59ce34
ip-10-0-143-60.ec2.internal    Ready    master   5h13m   v1.19.0+d59ce34
ip-10-0-157-32.ec2.internal    Ready    worker   5h4m    v1.19.0+d59ce34
ip-10-0-159-150.ec2.internal   Ready    master   5h14m   v1.19.0+d59ce34
ip-10-0-170-80.ec2.internal    Ready    worker   5h4m    v1.19.0+d59ce34
ip-10-0-173-10.ec2.internal    Ready    master   5h13m   v1.19.0+d59ce34
```

We have another cluster in the pool which is ready:

```console
$ oc get clusterpool -n hive
NAME                            READY   SIZE   BASEDOMAIN                  IMAGESET
ci-openshift-46-aws-us-east-1   1       1      hive.aws.ci.openshift.org   openshift-v4.6.0
```

Downsize the pool: set `clusterpool.spec.size=0`.

```console
$ oc get clusterpool -n hive ci-openshift-46-aws-us-east-1
NAME                            READY   SIZE   BASEDOMAIN                  IMAGESET
ci-openshift-46-aws-us-east-1   0       0      hive.aws.ci.openshift.org   openshift-v4.6.0

# The cluster is being uninstalled
$ oc get pod -n ci-openshift-46-aws-us-east-1-sfxhl
NAME                                                  READY   STATUS    RESTARTS   AGE
ci-openshift-46-aws-us-east-1-sfxhl-uninstall-2sq7x   1/1     Running   0          25s
```
