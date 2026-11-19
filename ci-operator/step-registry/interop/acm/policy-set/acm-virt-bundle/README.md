# ACM + Virt bundle

Steps for Advanced Cluster Management with OpenShift Virtualization. The directory is `interop/acm/policy-set/acm-virt-bundle/<operator>/<function>`. The ref name is that path with `/` replaced by `-`, so the operator comes before the function: `interop-acm-policy-set-acm-virt-bundle-mtv-cclm-migration-maps`.

Spoke OCP upgrade steps live under [`product-upgrade/spoke`](../../product-upgrade/spoke/upgrade/README.md). Jobs are listed in the [interop-testing README](../../../../../config/RedHatQE/interop-testing/README.md).

| Path | Ref |
|---|---|
| `mtv/integration` | `interop-acm-policy-set-acm-virt-bundle-mtv-integration` |
| `mtv/additional-config` | `interop-acm-policy-set-acm-virt-bundle-mtv-additional-config` |
| `mtv/register-providers` | `interop-acm-policy-set-acm-virt-bundle-mtv-register-providers` |
| `mtv/wait-providers` | `interop-acm-policy-set-acm-virt-bundle-mtv-wait-providers` |
| `mtv/cclm/migration-maps` | `interop-acm-policy-set-acm-virt-bundle-mtv-cclm-migration-maps` |
| `mtv/cclm/return-maps` | `interop-acm-policy-set-acm-virt-bundle-mtv-cclm-return-maps` |
| `mtv/cclm/bidir` | `interop-acm-policy-set-acm-virt-bundle-mtv-cclm-bidir` |
| `mtv/cclm/hub-spoke` | `interop-acm-policy-set-acm-virt-bundle-mtv-cclm-hub-spoke` |
| `cnv/hub-install` | `interop-acm-policy-set-acm-virt-bundle-cnv-hub-install` |
| `cnv/addon-install` | `interop-acm-policy-set-acm-virt-bundle-cnv-addon-install` |
| `cnv/install-policy` | `interop-acm-policy-set-acm-virt-bundle-cnv-install-policy` |
| `cnv/exchange-ca` | `interop-acm-policy-set-acm-virt-bundle-cnv-exchange-ca` |
| `odf/hub-install` | `interop-acm-policy-set-acm-virt-bundle-odf-hub-install` |
| `odf/spoke-install` | `interop-acm-policy-set-acm-virt-bundle-odf-spoke-install` |
| `submariner/install` | `interop-acm-policy-set-acm-virt-bundle-submariner-install` |
| `spoke/cluster-install` | `interop-acm-policy-set-acm-virt-bundle-spoke-cluster-install` |
| `spoke/cluster-uninstall` | `interop-acm-policy-set-acm-virt-bundle-spoke-cluster-uninstall` |

`mtv/cclm/migration-maps` creates both the NetworkMap and the StorageMap for the forward CCLM leg. `mtv/cclm/return-maps` creates the return-leg pair.
