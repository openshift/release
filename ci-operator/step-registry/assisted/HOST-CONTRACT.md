# Assisted Baremetal Host Contract

Provider-specific steps (e.g. OFCIR, vSphere, Nutanix) must emit a neutral hand-off
for the common Assisted workflows. After the provider provisions or acquires the host,
it **must** write `ci-machine-config.sh` in `$SHARED_DIR` with the following variables:

```bash
export IP="<reachable IPv4/IPv6 address>"
export SSH_KEY_FILE="<absolute path to private SSH key on provider side>"
export SSH_USER="<optional non-root username>"
export SSHOPTS=(<space separated ssh options>)
```

* `IP` – IP or hostname reachable from later steps.
* `SSH_KEY_FILE` – path to the private key that should be used for SSH.
* `SSH_USER` – optional. When omitted, downstream steps assume `root`.
* `SSHOPTS` – optional array declaration (matching bash syntax) with additional
  arguments (port, ProxyCommand, etc.). The built-in defaults (ConnectTimeout,
  StrictHostKeyChecking, etc.) are appended by consumers.

Downstream steps **must not** source provider-specific files such as
`packet-conf.sh`. They may only use `ci-machine-config.sh`, and should fail fast
if it is missing. This separation allows local tooling to skip provider
acquisition while still running the shared Assisted test logic verbatim. To
avoid open-coded validation, source `ci-operator/step-registry/assisted/common/lib/assisted-common-lib-commands.sh`
and call `assisted_load_host_contract` before invoking any SSH/Ansible logic.

For a provider that cannot populate one of the variables the file should still be
created and the scripts should fail early with a clear message. This keeps the
system idempotent and makes missing prerequisites obvious.
