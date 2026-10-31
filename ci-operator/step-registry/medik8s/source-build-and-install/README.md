# RHWA source-build and install

Shared step for the six OCP 5.0 cross-repo `*-pr-aws` jobs. Each operator config
builds a `pr-test-runner` image that embeds the Prow-selected checkout (usually a
PR) at `/opt/<operator>-ci-src`.

Sequence:

1. Prepare registry auth, Go caches, and rootless Podman.
2. Build/push operator, bundle, and catalog with `make dev-olm-catalog-push` (ttl.sh tags use `BUILD_ID`).
3. Verify the candidate bundle version.
4. Install the candidate with `operator-sdk run bundle`.
5. Install optional peer Quay bundles (`PEER_BUNDLES`; defaults: NHC→SNR, SNR/MDR→NHC).

NHC resolves `node-remediation-console:latest` and `must-gather:latest` to digests
at runtime. SBR passes `DEV_OLM_AGENT_IMAGE` into the shared make target.

Job-specific companions stay outside this step: `ssh-bastion` (NHC),
`medik8s-aws-credentials` (FAR), ODF/NFS refs (SBR), and the inline `e2e-test`
that clones `openshift/rhwa-system-tests`.
