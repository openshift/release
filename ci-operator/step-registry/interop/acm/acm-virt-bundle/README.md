# ACM+Virt JUnit steps

These steps write JUnit XML for ACM+Virt cross-cluster live migration. Setup and install steps stay in `p2p/` and `acm/interop-p2p/`.

| Step | What it checks |
|---|---|
| [`interop-acm-acm-virt-bundle-mtv-cclm-execute`](mtv/cclm/execute/interop-acm-acm-virt-bundle-mtv-cclm-execute-ref.yaml) | Spoke-to-spoke live migration |
| [`interop-acm-acm-virt-bundle-mtv-cclm-verify`](mtv/cclm/verify/interop-acm-acm-virt-bundle-mtv-cclm-verify-ref.yaml) | Post-migration checks on the destination spoke |
| [`interop-acm-acm-virt-bundle-mtv-cclm-execute-return`](mtv/cclm/execute-return/interop-acm-acm-virt-bundle-mtv-cclm-execute-return-ref.yaml) | Return live migration |
| [`interop-acm-acm-virt-bundle-mtv-cclm-verify-return`](mtv/cclm/verify-return/interop-acm-acm-virt-bundle-mtv-cclm-verify-return-ref.yaml) | Post-migration checks on the return leg |
| [`interop-acm-acm-virt-bundle-mtv-hub-spoke-execute`](mtv/hub-spoke/execute/interop-acm-acm-virt-bundle-mtv-hub-spoke-execute-ref.yaml) | Hub-to-spoke live migration |
| [`interop-acm-acm-virt-bundle-mtv-hub-spoke-verify`](mtv/hub-spoke/verify/interop-acm-acm-virt-bundle-mtv-hub-spoke-verify-ref.yaml) | Hub-to-spoke post-migration checks |

`p2p-cclm-bidir-migration-test` calls the spoke-to-spoke pair. `p2p-cclm-hub-spoke-migration-test` calls the hub-to-spoke pair.

Job layout: [interop-testing README](../../../../config/RedHatQE/interop-testing/README.md).
