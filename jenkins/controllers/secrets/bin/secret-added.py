#!/usr/bin/python

from __future__ import print_function
import sys
from kubernetes import client, config
import base64

from kubernetes.client.rest import ApiException
from jenkinsapi.credential import UsernamePasswordCredential
from jenkinsapi.credential import SSHKeyCredential
from jenkinsapi.credential import SecretTextCredential

import oc_common

def main(argv):
    if len(argv)==0:
        print('No arguments passed. Please specify a namespace, name, and value of ci.openshift.io/jenkins-secret-id annotation')
    elif len(argv)==3:
        processSecret(argv[0], argv[1], argv[2])

def processSecret(namespace, name, annotation_value=None):
    if not annotation_value:
        print("secret {}/{} is not applicable to Jenkins".format(namespace, name))
        return

    config.load_incluster_config()
    core_instance = client.CoreV1Api()

    try:
        secret = core_instance.read_namespaced_secret(name, namespace)
    except ApiException as e:
        print("Exception when calling CoreV1Api->read_namespaced_secret: {}\n".format(e))
        exit(1)

    j = oc_common.connect_to_jenkins()

    # Create/update a secret in the Jenkins server
    name = "_openshift/{}/{}".format(namespace, name)
    if secret.type == "kubernetes.io/basic-auth" or secret.type == "ci.openshift.io/user-pass":
        user_name = base64.b64decode(secret.data['username'])
        user_pass = base64.b64decode(secret.data['password'])
        cred = {
            'credential_id': annotation_value,
            'description': name,
            'userName': user_name,
            'password': user_pass
        }
        creds = j.credentials
        if name in creds:
            print("replacing existing secret {}".format(name))
            del creds[name]

        print("creating secret {} of type username-password".format(name))
        creds[name] = UsernamePasswordCredential(cred)
    elif secret.type == "ci.openshift.io/token" or secret.type == "ci.openshift.io/secret-text":
        token = ""
        if "secret" in secret.data:
            token = base64.b64decode(secret.data["secret"])
        elif "token" in secret.data:
            token = base64.b64decode(secret.data["token"])

        if secret:
            cred = {
                'credential_id': annotation_value,
                'description': name,
                'secret': token
            }
            creds = j.credentials
            if name in creds:
                print("replacing existing secret {}".format(name))
                del creds[name]

            print("creating secret {} of type secret-text".format(name))
            creds[name] = SecretTextCredential(cred)
    elif secret.type == "kubernetes.io/ssh-auth" or secret.type == "ci.openshift.io/secret-ssh":
        key = ""
        if "private_key" in secret.data:
            key = base64.b64decode(secret.data["private_key"])
        elif "ssh-privatekey" in secret.data:
            key = base64.b64decode(secret.data["ssh-privatekey"])
        
        passphrase = ""
        if "passphrase" in secret.data:
            passphrase = base64.b64decode(secret.data["passphrase"])

        username = ""
        if "username" in secret.data:
            username = base64.b64decode(secret.data["username"])

        cred = {
            'credential_id': annotation_value,
            'description': name,
            'userName': username,
            'passphrase': passphrase,
            'private_key': key,
        }
        creds = j.credentials
        if name in creds:
            print("replacing existing secret {}".format(name))
            del creds[name]

        print("creating secret {} of type ssh-key".format(name))
        creds[name] = SSHKeyCredential(cred)


if __name__ == "__main__":
    main(sys.argv[1:])
