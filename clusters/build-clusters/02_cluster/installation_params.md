# Build02: installation parameters

## [Configuring a GCP project](https://docs.openshift.com/container-platform/4.4/installing/installing_gcp/installing-gcp-account.html)

Create a new project on GCP.

### [Configuring DNS for GCP](https://docs.openshift.com/container-platform/4.4/installing/installing_gcp/installing-gcp-account.html#installation-gcp-dns_installing-gcp-account)

* base-domain: It will be a part of the default hostname for routes.

### [Creating a service account in GCP](https://docs.openshift.com/container-platform/4.4/installing/installing_gcp/installing-gcp-account.html#installation-gcp-service-account_installing-gcp-account)

The service account key is required to create a cluster.

GCP regions: us-east1 (Moncks Corner, South Carolina, USA)

### pull-secret

> oc get secret -n ci cluster-secrets-gcp  -o jsonpath='{.data.pull-secret}' | base64 -d

(We use `cluster-secrets-aws` for `build01`.)

## Customization

### SSH key

Install it. Using or not, it is the decision later.

### machine type

|         | master         | worker         |
|---------|----------------|----------------|
| api.ci  | n1-standard-16 | n1-standard-16 |
| build01 | m5.2xlarge     | m5.4xlarge     |
| build02 | n1-standard-8  | n1-standard-16 |


|         | master                   | worker                   |
|---------|--------------------------|--------------------------|
| api.ci  | 150G SSD persistent disk | 300G SSD persistent disk |
| build01 | 150G EBS gp2             | 700G EBS gp2             |
| build02 | 150G SSD persistent disk | 300G SSD persistent disk |


* api.ci's masters were `n1-standard-8`. We resized them after creating `build01`
* build01's 700G disks on workers are for burst balance issue.
* n1-standard-8: 8 vCPUs, 30 GB memory
* n1-standard-16: 16 vCPUs, 60 GB memory
* m5.2xlarge: 8 vCPUs, 32G Memory
* m5.4xlarge: 16 vCPUs, 64G Memory

Disk size on GCP: [asked in slack](https://coreos.slack.com/archives/C68TNFWA2/p1588701464413000) and [bz1831838](https://bugzilla.redhat.com/show_bug.cgi?id=1831838).
