# ACM CCLM steps

Interop steps for Advanced Cluster Management with OpenShift Virtualization. The path follows `interop/<main-operator>/<functional-group>/<target>/<test>`. The ref name is that path with `/` replaced by `-`.

Jobs that call these refs are listed in the [interop-testing README](../../../../config/RedHatQE/interop-testing/README.md).

| Path | Ref | What it does |
|---|---|---|
| `mtv/integration` | `interop-acm-cclm-mtv-integration` | Enable ACM `cnv-mtv-integrations` so ACM owns MTV on the hub |
| `mtv/additional-config` | `interop-acm-cclm-mtv-additional-config` | Configure ForkliftController for CCLM |
| `mtv/register-providers` | `interop-acm-cclm-mtv-register-providers` | Register spoke providers on the hub |
| `spoke/cluster-install` | `interop-acm-cclm-spoke-cluster-install` | Provision ACM spokes with Hive. [README](spoke/cluster-install/README.md) |
| `cnv/hub-install` | `interop-acm-cclm-cnv-hub-install` | Install OpenShift Virtualization on the hub |
| `cnv/addon-install` | `interop-acm-cclm-cnv-addon-install` | Install OpenShift Virtualization on spokes through the ACM add-on |
| `cnv/install-policy` | `interop-acm-cclm-cnv-install-policy` | Install OpenShift Virtualization on spokes with an ACM policy. [README](cnv/install-policy/README.md) |
| `odf/hub-install` | `interop-acm-cclm-odf-hub-install` | Install ODF on the hub |
| `odf/spoke-install` | `interop-acm-cclm-odf-spoke-install` | Install ODF on spokes |
| `submariner/install` | `interop-acm-cclm-submariner-install` | Chain: cloud prepare, broker join, connectivity verify |
| `cnv/exchange-ca` | `interop-acm-cclm-cnv-exchange-ca` | Exchange KubeVirt CA bundles across clusters |
| `mtv/wait-providers` | `interop-acm-cclm-mtv-wait-providers` | Wait until ACM-created MTV providers are Ready |
| `mtv/migration-maps` | `interop-acm-cclm-mtv-migration-maps` | Create forward NetworkMap and StorageMap |
| `mtv/return-maps` | `interop-acm-cclm-mtv-return-maps` | Create return-leg NetworkMap and StorageMap |
| `cnv-mtv/bidir` | `interop-acm-cclm-cnv-mtv-bidir` | Chain: create VMs, migrate spoke-1 to spoke-2, verify, return, verify |
| `cnv-mtv/hub-spoke` | `interop-acm-cclm-cnv-mtv-hub-spoke` | Workflow: hub-spoke round-trip CCLM |
| `spoke/cluster-uninstall` | `interop-acm-cclm-spoke-cluster-uninstall` | Deprovision Hive-managed spokes. [README](spoke/cluster-uninstall/README.md) |

`odf/hub-install`, `spoke/cluster-install`, `odf/spoke-install`, `cnv/install-policy`, and `spoke/cluster-uninstall` are also used by the ACM+Virt p2p and EUS upgrade jobs. `cnv/hub-install`, `mtv/additional-config`, and `mtv/register-providers` are used by the hub-spoke CCLM workflow. The other rows are the 4.22 spoke-to-spoke CCLM job.
