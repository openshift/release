# security context constraints

This folder contains the SCCs that we created. Note that [we are not supposed to modify any build-in SCC](https://docs.openshift.com/container-platform/4.3/authentication/managing-security-context-constraints.html).

## `vpn`

The [`vpn.yaml`](./vpn.yaml) SCC is used by multi-stage tests in `ci-operator`
which request a VPN connection.  It is based on the `restricted` SCC (divergent
fields have the original value in comments) with looser permissions for host
path mounts, capabilities, SELinux contexts, and UIDs.  Details are described in
the [design document](https://docs.google.com/document/d/1mPjrHVS1EvmLdq4kGhRazTpGu6xVZDyGpVAphVZhX4w/edit?resourcekey=0-KA-qXXq1J2bTR7o6Kit9Vw).
