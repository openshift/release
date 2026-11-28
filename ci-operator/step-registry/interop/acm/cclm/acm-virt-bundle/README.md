# ACM+Virt JUnit steps

These steps write JUnit XML for ACM+Virt cross-cluster live migration (CCLM). Setup and install steps stay in `p2p/` and `acm/interop-p2p/`.

Paths follow `interop/<main-operator>/<functional-group>/<target-operators>/<test-name>` from the [interop registry README](../../../README.md). `acm-virt-bundle` is the bundle, in the same slot as `opp-bundle`. Parent directories separate words with `-`. The step stub separates functional components with `--`.

The spoke-to-spoke test names are `execute` and `execute--return`. The checks after those legs are `verify` and `verify--return`.

| Step | Path | What it checks |
|---|---|---|
| `interop-acm-cclm-acm-virt-bundle-execute` | [`execute`](execute/interop-acm-cclm-acm-virt-bundle-execute-ref.yaml) | Spoke-to-spoke, spoke-1 to spoke-2 |
| `interop-acm-cclm-acm-virt-bundle-execute--return` | [`execute--return`](execute--return/interop-acm-cclm-acm-virt-bundle-execute--return-ref.yaml) | Return leg, spoke-2 back to spoke-1 |
| `interop-acm-cclm-acm-virt-bundle-verify` | [`verify`](verify/interop-acm-cclm-acm-virt-bundle-verify-ref.yaml) | Checks after the forward leg |
| `interop-acm-cclm-acm-virt-bundle-verify--return` | [`verify--return`](verify--return/interop-acm-cclm-acm-virt-bundle-verify--return-ref.yaml) | Checks after the return leg |
| `interop-acm-cclm-acm-virt-bundle-hub-spoke` | [`hub-spoke`](hub-spoke/interop-acm-cclm-acm-virt-bundle-hub-spoke-ref.yaml) | Hub and spoke, both directions |
| `interop-acm-cclm-acm-virt-bundle-hub-spoke--verify` | [`hub-spoke--verify`](hub-spoke--verify/interop-acm-cclm-acm-virt-bundle-hub-spoke--verify-ref.yaml) | Checks after the hub-and-spoke run |

MTV is installed on the ACM hub and runs these migrations. It is not a path component.

- **Main operator**: `acm`
- **Functional group**: `cclm`
- **Bundle**: `acm-virt-bundle`
- **Test name**: `execute`, `execute--return`, `verify`, `verify--return`, or `hub-spoke` with `--verify`

`p2p-cclm-bidir-migration-test` calls the spoke-to-spoke pair. `p2p-cclm-hub-spoke-migration-test` calls the hub-and-spoke pair.

Job layout: [interop-testing README](../../../../../config/RedHatQE/interop-testing/README.md).
