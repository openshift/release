# Azure Credentials Rotation

The secrets such as `cluster-secrets-azure4` include the Azure credentials that OpenShift installer uses to install clusters for e2e tests.
Because [Azure forces an expiry date for the credentials](https://redhat-internal.slack.com/archives/CBN38N3MW/p1675693067516879?thread_ts=1675591291.220619&cid=CBN38N3MW), we have to refresh them in our secrets.
The current one was configured on Feb 6 2023 and is valid for 730 days.

They are stored in the items `os4-installer.openshift-ci.azure` and `os4-installer.openshift-ci2.azure` in Vault.
To rotate the credentials,

- Ask [#forum-pge-cloud-ops](https://redhat-internal.slack.com/archives/CBUT43E94) for a new `Secret`.
- Replace the value of `clientSecret` of `osServicePrincipal.json` in the above TWO items in Vault with the SAME `Secret` obtained from the DPP team.
Note that the two sets of credentials are from the same Service Principal, hence the same `Secret`, with different subscriptions.

The secrets using the items will be refreshed after the next run of `ProwJob/periodic-ci-secret-bootstrap`.
