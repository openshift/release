# Deploy the OpenShift CI instance to GCE

    $ ../bin/local.sh
    $ export PR_REPO_URL=<a yum repo base URL containing OpenShift RPMs>
    $ ansible-playbook playbooks/provision.yaml

Will download the appropriate version of OpenShift and install it to
GCE. You must populate the `data` directory with the appropriate secret
data first:

* ssl.crt / ssl.key: certificates for the master
* gce.json: Service account credentials for installing the master
* gce-registry.json: Service account credentials for the registry to use against GCS
* identity-providers.json: GitHub OAuth info
* ssh-privatekey / ssh-publickey: An SSH key pair for connecting to the masters (optional)

The image `openshift/origin-gce:latest` is used as the environment for Ansible, and contains
a copy of the `openshift-ansible` code and `origin-gce`.