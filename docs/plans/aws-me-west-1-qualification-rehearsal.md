# me-west-1 AWS region qualification: temporary rehearsal PR (DNM)

## Context
AWS is adding a new opt-in region, `me-west-1`, and the test plan needs installs qualified there: P0 default/BYO-VPC/private/STS, P1 UPI/arm64/mixed-arch, and the conditional proxy/disconnected/custom-DNS/dualstack cases. The vehicle is a throw-away openshift/release PR (marked `[DNM]` and put on `/hold`) whose jobs run through `/pj-rehearse`. It targets the openshift/installer branches **main, release-5.1, release-5.0, release-4.22 and release-4.21**. Each job uses cluster profile **aws-qe**, with the region forced to `me-west-1`.

Constraints found during research:
- The aws-qe boskos lease only ever gives `LEASED_RESOURCE` = `us-east-1` or `ap-northeast-1`.
- Only `ipi-conf-aws` and the two blackholenetwork steps honor `AWS_REGION_OVERWRITE`. The other AWS steps hard-read `LEASED_RESOURCE`, so the PR temporarily patches them. When the variable is unset they behave exactly as before.
- I'm reusing the existing installer presubmits wherever one exists. For the gaps (STS, arm64, disconnected) I use the public `openshift-e2e-aws-*` workflows.

## 1. Step-registry patches (temporary)
For each step below:
- **Script:** replace the lease read with `REGION="${AWS_REGION_OVERWRITE:-${LEASED_RESOURCE}}"` (same form as `ipi/conf/aws/ipi-conf-aws-commands.sh:42`).
- **Ref YAML:** add an env entry `AWS_REGION_OVERWRITE` (default `""`) to the step's ref YAML, documented like `ipi/conf/aws/blackholenetwork/ipi-conf-aws-blackholenetwork-ref.yaml:18`.

Plain `REGION="${LEASED_RESOURCE}"`:
- `aws/provision/iam-user` (:17), `aws/deprovision/users-and-policies` (:11), `aws/deprovision/verification` (:10)
- `aws/provision/security-group` (:24), `aws/deprovision/security-group` (:16), `aws/deprovision/s3buckets` (:10)
- `aws/provision/vpc/disconnected` (:20), `aws/provision/cco-manual-users/static` (:17)
- `aws/provision/public-custom-dns` (:14), `aws/provision/public-custom-dns/post` (:14)
- `ipi/conf/aws/custom-vpc` (:31), `ipi/conf/aws/default` (:20)
- `ipi/conf/aws/oidc-creds-provision` (:31), `ipi/conf/aws/oidc-creds-deprovision` (:8)
- `ipi/deprovision/aws/custom-security-groups` (:16), `ipi/deprovision/aws/sharednetwork` (:10)
- `cucushift/installer/check/aws/private` (:15), `cucushift/installer/check/user-provisioned-dns` (:65)

Other forms:
- `ipi/conf/aws/sharednetwork` (:20, :22): patch both `AWS_DEFAULT_REGION` and `REGION`.
- `ipi/conf/aws/byo-ipv4-pool-public`: not patched. BYO public IPv4 pool is not qualified in me-west-1 (Classic BYOIP pools can't be shared cross-account into the QE account), so no me-west-1 job uses this step.
- `ipi/install/install/aws` (:259): patch `local REGION=...`. It is only used when `ADD_INGRESS_RECORDS_MANUALLY=yes`; patch it anyway for safety.
- The five steps that already accept `REGION` (`REGION=${REGION:-$LEASED_RESOURCE}`) become `REGION=${AWS_REGION_OVERWRITE:-${REGION:-$LEASED_RESOURCE}}`. `AWS_REGION_OVERWRITE` is the top authority so it drives every job uniformly and create/cleanup always agree; production, which sets `REGION` but not the override, is unchanged. The steps are:
  - `aws/provision/vpc/shared` (:39)
  - `aws/provision/tags-for-byo-vpc` (:17)
  - `aws/deprovision/stacks` (:5)
  - `aws/provision/bastionhost` (:17)
  - `aws/provision/kms-key` (:17)
- `aws/provision/bastionhost` (:149) already maps `me-west-1` → `t3.medium` (`t3a` is not offered there). Do not add a `t3a.medium` branch.

No change is needed for steps that read the region from install-config or `metadata.json`: `ipi-deprovision-deprovision`, `gather-aws-console`, `upi-install-aws-cluster`, `upi-deprovision-aws`, `ipi-conf-aws-proxy`, `ipi-conf-aws-custom-security-groups`.

## 2. New presubmit tests (per branch)
These go in `ci-operator/config/openshift/installer/openshift-installer-{main,release-5.1,release-5.0,release-4.22,release-4.21}.yaml`.

Each job:
- copies the branch's own existing stanza (so 4.22/4.21 keep TechPreview dualstack variants and their own env);
- sets `always_run: false` and `optional: true`;
- sets `cluster_profile: aws-qe`;
- adds `AWS_REGION_OVERWRITE: me-west-1` and `BASE_DOMAIN: qe.devcluster.openshift.com` to the env (except custom-dns which inherits BASE_DOMAIN from the workflow).
- all jobs run the `openshift-e2e-test` conformance suite **except** private and disconnected.

| Plan item | New test `as:` | Source | E2E suite |
|---|---|---|---|
| P0 default (conformance) | `e2e-aws-mewest1-ipi` | `openshift-e2e-aws` | yes |
| P0 default (instance types / AZs) | `e2e-aws-mewest1-default-config` | `ipi-conf-aws-default` + `openshift-e2e-test` | yes |
| P0 existing VPC | `e2e-aws-mewest1-shared-vpc` | `e2e-aws-ovn-shared-vpc-custom-security-groups` | yes |
| P0 private | `e2e-aws-mewest1-private` | `aws-private` (cucushift check only) | **no** |
| P0 STS | `e2e-aws-mewest1-sts` | `openshift-e2e-aws-manual-oidc-sts` | yes |
| P1 UPI | `e2e-aws-mewest1-upi` | `openshift-e2e-aws-upi` | yes |
| P1 arm64 | `e2e-aws-mewest1-arm64` | `openshift-e2e-aws` + arm64 arch | yes |
| P1 mixed-arch | `e2e-aws-mewest1-heterogeneous` | `openshift-e2e-aws-heterogeneous-day-0` | yes |
| P0 proxy | `e2e-aws-mewest1-proxy` | `openshift-e2e-aws-proxy` | yes |
| P0 disconnected | `e2e-aws-mewest1-disconnected` | `openshift-e2e-aws-disconnected` (health check only) | **no** |
| P0 custom DNS | `e2e-aws-mewest1-custom-dns` | `openshift-e2e-aws-custom-dns` | yes |
| P0 dualstack IPv4 | `e2e-aws-mewest1-dualstack-ipv4-primary` | `openshift-e2e-aws` + DualStackIPv4Primary | yes |
| P0 dualstack IPv6 | `e2e-aws-mewest1-dualstack-ipv6-primary` | `openshift-e2e-aws` + DualStackIPv6Primary | yes |

That is 13 tests × 5 branches = 65 jobs. Prow names look like `pull-ci-openshift-installer-<branch>-e2e-aws-mewest1-<scenario>`.

Branch-specific notes:
- **4.22, 4.21**: Dualstack stanzas include `FEATURE_SET: TechPreviewNoUpgrade`.
- **4.21**: Has no existing dualstack/heterogeneous source stanzas, but the shared workflows work cross-version. Failures are valid qualification data.

## 3. Generate, commit, PR
1. Create branch `me-west-1-qualification` from `master`.
2. Run `make update` to regenerate `ci-operator/jobs/openshift/installer/*-presubmits.yaml`, then run `make validate-step-registry` and `make checkconfig`.
3. Commit. Push to the user's fork and open the PR titled `[DNM] AWS me-west-1 region qualification rehearsals`. The PR body states that it must not merge, gives the test-plan mapping table above, and ends with the attribution line. Comment `/hold`.
4. Rehearse explicitly, because the step patches make pj-rehearse select hundreds of unrelated jobs:
   - first comment `/pj-rehearse pull-ci-openshift-installer-main-e2e-aws-mewest1-ipi pull-ci-openshift-installer-main-e2e-aws-mewest1-default-config` (a smoke check of region, opt-in and AMI);
   - then the rest of `main`, then 5.1, 5.0 and 4.22, in batches.

## Known risks / prerequisites (call out in PR body)
- **Opt-in region:** `me-west-1` must be enabled on the aws-qe account (`aws account list-regions` / `ec2 describe-regions --all-regions`), and regional STS must be reachable.
- **Installer and RHCOS support:**
  - If the installer's region list or RHCOS stream lacks `me-west-1` on a branch (likely 4.22/5.0), IPI fails at install-config validation or AMI lookup. The workaround is to copy an RHCOS AMI into the region and set `CONTROL_PLANE_AMI`/`COMPUTE_AMI` (supported by `ipi-conf-aws`).
  - UPI (`upi-install-aws-cluster` :205) has no null check for a missing AMI.
- **FCOS AMIs:** the bastion (`aws-provision-bastionhost` :110) and the proxy (`ipi-conf-aws-proxy` :250) look up FCOS `stable.json` by region. If FCOS hasn't published to `me-west-1` yet, set `BASTION_HOST_AMI` or expect failures in private, disconnected, proxy and UPI.
- **Instance types:** `m6a`/`m6g` availability is probed dynamically by `ipi-conf-aws`. Check arm64 m6g offerings in the region.

## Verification
- **Local:** `make update`, `make validate-step-registry` and `make checkconfig` all pass. `git diff --stat` shows only the step scripts/refs above, the 4 installer configs and the regenerated installer presubmit job files.
- **Unset case:** `grep -rn 'REGION=.*LEASED_RESOURCE' <patched files>` shows that every patched line keeps `LEASED_RESOURCE` as the fallback, so behavior is unchanged when the variable is unset.
- **Rehearsals:** in the build log, `ipi-conf-aws` prints the region, and the install-config artifact must show `platform.aws.region: me-west-1`. For every scenario, the deprovision and `aws-deprovision-verification` steps must report me-west-1 and leave no resources behind.
