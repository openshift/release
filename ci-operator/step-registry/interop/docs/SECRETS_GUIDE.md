# (WIP) OpenShift CI Interop Scenario Secrets Guide<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Overview](#overview)
  - [Create Collection](#create-collection)
  - [Get Access to a Scenario Collection](#get-access-to-a-scenario-collection)
  - [Get Access to the cspi-qe Collection](#get-access-to-the-cspi-qe-collection)
  - [Sign in to Vault](#sign-in-to-vault)
  - [How Secrets are Made Available](#how-secrets-are-made-available)

## Overview
OpenShift CI provides its own Hashicorp Vault instance that we can use. This makes the use of secrets standard for anyone who needs them. Most of everything that we do for secrets was discovered from the OpenShift CI documentation [Adding a New Secret to CI](https://docs.ci.openshift.org/docs/how-tos/adding-a-new-secret-to-ci/)

### Create Collection
Each scenario being tested will have its own collection. This allows us to prevent secret sharing between members of other collections meant to hold secrets for other scenarios.

First go to [selfservice.vault.ci.openshift.org](https://selfservice.vault.ci.openshift.org/secretcollection?ui=true) and login.

If you do not see a collection in the table for the scenario that your testing it either hasn't been created yet or you don't have access to it.

Please reach out on slack at [#forum-qe-cspi-ocp-ci](https://coreos.slack.com/archives/C047Y0DPEJU) to ask if the collection for the scenario you are testing has already been created. If it has go to the [next section](#get-access-to-collection)

If it hasn't you can create the collection by clicking the `New Collection` button and adding the name. Follow the naming structure of `{product short name}-qe`.
### Get Access to a Scenario Collection
If you do not see a collection in the table and you have verified that it exists then you just need to be added by one of the collection owners. Please reach out on slack at [#forum-qe-cspi-ocp-ci](https://coreos.slack.com/archives/C047Y0DPEJU) and provide details about what and why you would like to be added to a specific collection.

### Get Access to the cspi-qe Collection
This collection holds team specific information holding things like AWS creds, pull secrets, ..etc. If you need access to this collection reach out on slack at [#forum-qe-cspi-ocp-ci](https://coreos.slack.com/archives/C047Y0DPEJU) and provide details about why you would like to be added to the cspi-qe collection.

### Sign in to Vault
Now that you are a member of a collection you can login to vault and access that collection.

Go to [vault.ci.openshift.org](https://vault.ci.openshift.org/ui/vault/auth?with=oidc%2F) and click `Sign in with OIDC Provider`.

You'll be redirected to your secrets homepage. 
`cubbyhole/` is just your users personal space for any secrets you want to store. 
We care about `kv/` this is where you'll find secret directories that correspond to the collections that you are a member of.

From here you can use the UI to view, create, edit, and delete secrets.

### How Secrets are Made Available
Now that you have your secrets in order we need to know how to make use of them during an OpenShift CI run.

