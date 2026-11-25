# ci-operator-configresolver (app.ci remnant)

Public traffic lives on **core-ci** (`config.ci` / `steps.ci`).

This directory keeps only the ServiceAccount and `ocp-priv` Role/RoleBinding.
core-ci mounts `sa.ci-operator-configresolver.app.ci.config` for `/integratedStream`.
