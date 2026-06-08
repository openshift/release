# Expose boskos service

The boskos service on api.ci cluster is exposed via router because test pods on build farm need to access it.

It is protected with [openshift/oauth-proxy](https://github.com/openshift/oauth-proxy#command-line-options).

Generate password file with 

```bash
# podman run -it --rm fedora:30 bash
# dnf install httpd-tools
# htpasswd -c -b -s ./ci.htpasswd <username> <password>

```

Upload the file to BitWarden `boskos-oauth-proxy`.

The file `ci.htpasswd` is mounted to pod `oauth-proxy` and the `username/password` will be used for test pods to access the boskos router.
