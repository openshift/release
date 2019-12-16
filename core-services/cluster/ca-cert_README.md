# CA Certificates of api.ci cluster

Those steps are applied to api.ci cluster with

```bash
$ oc version --short=true
...
Server Version: v1.11.0+d4cacc0

```

## Checking the certificate

```bash
# curl --insecure -v https://registry.svc.ci.openshift.org 2>&1 | awk 'BEGIN { cert=0 } /^\* Server certificate:/ { cert=1 } /^\*/ { if (cert) print }'
* Server certificate:
*  subject: C=US; ST=North Carolina; L=Raleigh; O=Red Hat, Inc.; OU=RHC Cloud Operations; CN=*.svc.ci.openshift.org
*  start date: Dec  6 00:00:00 2018 GMT
*  expire date: Dec 11 12:00:00 2019 GMT
*  issuer: C=US; O=DigiCert Inc; OU=www.digicert.com; CN=DigiCert SHA2 High Assurance Server CA
*  SSL certificate verify ok.
...
```

Cerificates will expire on `Dec 11 12:00:00 2019 GMT`.

## Instructions: cert. rotation

### Get the CA certificates

* #sd-sre: [confirming](https://coreos.slack.com/archives/CCX9DB894/p1575300232249000) we need a ticket from [redhat.service-now](https://redhat.service-now.com/help)
* ticket created: [RH0061935](https://redhat.service-now.com/surl.do?n=RH0061935)
    
```bash
### The new cert is in the attachment of the ticket; Download them
$ ls *api*.zip
api_ci_openshift_org_8015712.zip origin-ci-ig-m-428p.api.zip
### unzip 
$ cd api_ci_openshift_org_8015712
$ ls ./*.crt
api_ci_openshift_org_8015712/api_ci_openshift_org.crt api_ci_openshift_org_8015712/DigiCertCA.crt
### note that the order of files matters, although `openssl verify ssl.crt` does not pass.
$ cat api_ci_openshift_org.crt DigiCertCA.crt > ssl.crt 

### the keys are added into the tickets
$ ls *.key
wildcard.svc.ci.openshift.org.key api.ci.openshift.org.key
```

### back up existing certs:

```bash
$ for master in origin-ci-ig-m-428p origin-ci-ig-m-f3g1 origin-ci-ig-m-pbj3; do gcloud compute ssh "${master}" -- "sudo tar -zcvf /root/master.bk.20191202.tar.gz /etc/origin/master"; done

$ for master in origin-ci-ig-m-428p origin-ci-ig-m-f3g1 origin-ci-ig-m-pbj3; do gcloud compute ssh "${master}" -- "sudo cp master.bk.20191202.tar.gz /home/hongkliu/"; done

$ for master in origin-ci-ig-m-428p origin-ci-ig-m-f3g1 origin-ci-ig-m-pbj3; do gcloud compute scp "${master}:/home/hongkliu/master.bk.20191202.tar.gz" "./${master}.master.bk.20191202.tar.gz"; done


$ mkdir ~/Downloads/router
$ oc extract --as system:admin -n default secret/router-certs --to ~/Downloads/router 
/home/hongkliu/Downloads/router/tls.crt
/home/hongkliu/Downloads/router/tls.key

$ oc get secret -n default --as system:admin router-certs -o yaml > ~/Downloads/default-router-certs.apici.yaml
```

### redeploy certificates on masters
     
```bash
###copy the key
$ for master in origin-ci-ig-m-428p origin-ci-ig-m-f3g1 origin-ci-ig-m-pbj3; do gcloud compute scp ./ssl.key "${master}:/etc/origin/master/named_certificates/ssl.key"; done 
### copy the crt
$ for master in origin-ci-ig-m-428p origin-ci-ig-m-f3g1 origin-ci-ig-m-pbj3; do gcloud compute scp ./ssl.cert "${master}:/etc/origin/master/named_certificates/ssl.crt"; done
###restart master
$ for master in origin-ci-ig-m-428p origin-ci-ig-m-f3g1 origin-ci-ig-m-pbj3; do gcloud compute ssh "${master}" -- "sudo /usr/local/bin/master-restart api"; done
### checking on the logs of the api-server container
# docker ps -a | grep -v POD | grep api
# docker logs container_id_d675ff5249a1 > /tmp/d675ff5249a1.log 2>&1
# grep certificate /tmp/d675ff5249a1.log
###shows no error

$ curl --insecure -v https://api.ci.openshift.org:443 2>&1 | awk 'BEGIN { cert=0 } /^\* Server certificate:/ { cert=1 } /^\*/ { if (cert) print }'
* Server certificate:
*  subject: C=US; ST=North Carolina; L=Raleigh; O=Red Hat, Inc.; OU=RHC Cloud Operations; CN=api.ci.openshift.org
*  start date: Sep 25 00:00:00 2019 GMT
*  expire date: Dec 28 00:00:00 2021 GMT
*  issuer: C=US; O=DigiCert Inc; OU=www.digicert.com; CN=DigiCert SHA2 High Assurance Server CA
*  SSL certificate verify ok.
...
```

### redeploy certificates of router

```bash
$ oc project default
$ cat star_svc_ci_openshift_org.crt DigiCertCA.crt wildcard.svc.ci.openshift.org.key > router.pem
$ oc create secret tls router-certs --cert=router.pem --key=wildcard.svc.ci.openshift.org.key -o yaml --dry-run | oc --as system:admin replace -f -
$ oc --as system:admin rollout latest dc/router
$ oc get pod -l deploymentconfig=router
NAME             READY   STATUS    RESTARTS   AGE
router-7-4pkkp   1/1     Running   0          10m
router-7-qqtwr   1/1     Running   0          10m
router-7-zqpbn   1/1     Running   0          10m
```

Then check:

```
$ curl --insecure -v https://registry.svc.ci.openshift.org 2>&1 | awk 'BEGIN { cert=0 } /^\* Server certificate:/ { cert=1 } /^\*/ { if (cert) print }'
* Server certificate:
*  subject: C=US; ST=North Carolina; L=Raleigh; O=Red Hat, Inc.; OU=RHC Cloud Operations; CN=*.svc.ci.openshift.org
*  start date: Sep 25 00:00:00 2019 GMT
*  expire date: Dec 28 00:00:00 2021 GMT
*  issuer: C=US; O=DigiCert Inc; OU=www.digicert.com; CN=DigiCert SHA2 High Assurance Server CA
*  SSL certificate verify ok.

$ curl --insecure -v https://boskos-ci.svc.ci.openshift.org 2>&1 | awk 'BEGIN { cert=0 } /^\* Server certificate:/ { cert=1 } /^\*/ { if (cert) print }'
* Server certificate:
*  subject: C=US; ST=North Carolina; L=Raleigh; O=Red Hat, Inc.; OU=RHC Cloud Operations; CN=*.svc.ci.openshift.org
*  start date: Sep 25 00:00:00 2019 GMT
*  expire date: Dec 28 00:00:00 2021 GMT
*  issuer: C=US; O=DigiCert Inc; OU=www.digicert.com; CN=DigiCert SHA2 High Assurance Server CA
*  SSL certificate verify ok.
```


