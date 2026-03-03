# gs-baremetal-create-image (Day 0)

Runs `openshift-install agent create image` to produce the agent ISO. Must run after **gs-baremetal-conf**; output is consumed by **gs-baremetal-orchestrate** (Day 1).

## Inputs

- **SHARED_DIR/install-config.yaml**, **SHARED_DIR/agent-config.yaml** (from gs-baremetal-conf).
- **Cluster profile**: pull-secret for `oc adm release extract`.
- **release:latest** dependency for `OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE`.

## Outputs

- **INSTALL_DIR** (default `SHARED_DIR/install-dir`): contains install-config.yaml, agent-config.yaml, `agent.<arch>.iso`, and a copy of the openshift-install binary.
- **SHARED_DIR/install_dir_path**: written with the INSTALL_DIR path when not set via env, so gs-baremetal-orchestrate can use the same path.

## Workflow order

Run after **ref: gs-baremetal-conf**, before **ref: gs-baremetal-orchestrate**. No need to set INSTALL_DIR in the workflow; the orchestrate step reads it from SHARED_DIR/install_dir_path when unset.
