# Google Cloud Dedicated (GCD) CI Configuration

This directory contains step-registry components for running OpenShift
installer e2e tests on Google Cloud Dedicated (sovereign cloud).

## Overview

The `e2e-gcd-ovn-private-techpreview` job installs a private OpenShift
cluster on GCD using IPI with a service account key for authentication.
GCD support is currently under TechPreview.

## Authentication

Authentication uses a GCD service account key (`gce.json`) stored in the
`cluster-secrets-gcd` vault secret. The key is a standard
`service_account` type JSON with a GCD-specific `universe_domain` field.

Each CI step reads the `universe_domain` from `gce.json` and calls
`gcloud config set universe_domain` before authenticating with
`gcloud auth activate-service-account`.

## Cluster Profile Secret (`cluster-secrets-gcd`)

Stored in the CI vault at `selfservice.vault.ci.openshift.org` under
collection `gcd-cluster-profile`.

| Key | Description |
|-----|-------------|
| `gce.json` | GCD service account key (type `service_account`) |
| `openshift_gcp_project` | GCD project ID with prefix: `eu0:openshift` |
| `public_hosted_zone` | Base domain for DNS: `ci.gcd.devcluster.openshift.com` |
| `ssh-publickey` | SSH public key for node access |
| `ssh-privatekey` | SSH private key for node access |

Vault metadata for secret sync:
```
secretsync/target-namespace: ci
secretsync/target-name: cluster-secrets-gcd
```

## GCD-specific Requirements

### Universe Domain

GCD uses `apis-berlin-build0.goog` instead of `googleapis.com`. The
`universe_domain` field in `gce.json` tells gcloud and the Google SDK
to route API calls to GCD endpoints. Each CI step detects this
automatically from the credentials file.

### Machine Types

GCD only has C3, M3, and A3 Edge machine series. The common N2, E2,
and T2A types used in standard GCP CI jobs are not available.

- Cluster nodes: configured by the installer based on GCD defaults
- Bastion host: `c3-standard-4`

### Disk Types

GCD only supports Hyperdisk Balanced. Persistent Disk and Local SSD
are not available.

### OS Images

GCD does not have access to public GCP image projects. Images must be
uploaded to the GCD project.

- **Cluster nodes**: `rhcos10` (RHCOS image published to GCD)
- **Bastion host**: `fedora-coreos-41-20241122-3-0-gcp-x86-64`
  (uploaded to `eu0:openshift` project)

The Fedora CoreOS image must be created with `--guest-os-features=GVNIC`
because C3 machines require the GVNIC (Google Virtual NIC) interface.
Without this flag, instance creation fails with:

```
NetworkInterface NicType can only be set to GVNIC on instances with
GVNIC GuestOsFeature.
```

To upload the bastion image:
```bash
export GOOGLE_CLOUD_UNIVERSE_DOMAIN=apis-berlin-build0.goog
gcloud config set universe_domain apis-berlin-build0.goog

gcloud storage cp fedora-coreos.tar.gz gs://openshift-ci-images/
gcloud compute images create fedora-coreos-41-20241122-3-0-gcp-x86-64 \
  --source-uri=gs://openshift-ci-images/fedora-coreos-41-20241122-3-0-gcp-x86-64.tar.gz \
  --guest-os-features=GVNIC \
  --project=eu0:openshift
```

### DNS

GCD only supports private DNS zones. A private managed zone must exist
for the base domain before running jobs:

```bash
gcloud dns managed-zones create ci-gcd-zone \
  --dns-name="ci.gcd.devcluster.openshift.com." \
  --visibility=private \
  --description="CI base domain for GCD installer tests" \
  --project=eu0:openshift \
  --networks=""
```

### Private Cluster

The job sets `PUBLISH: Internal` because GCD has no public DNS. The
workflow provisions a VPC, bastion host, and proxy before installing
the cluster, so CI pods can reach the internal API endpoint.

### Region

GCD Berlin has a single region `u-germany-northeast1` with three zones
(a, b, c). The Boskos quota slices use this region.

### Project ID Format

GCD project IDs use a prefix: `eu0:openshift`. The installer detects
sovereign cloud from the `eu0:` prefix.

## Workflow Steps

The `openshift-e2e-gcd` workflow:

**Pre (ipi-gcd-pre chain):**
1. `gcp-provision-vpc` - creates VPC, subnets, router, NAT
2. `ignition-bastionhost` - generates bastion ignition config
3. `gcp-provision-bastionhost` - creates bastion VM with proxy
4. `proxy-config-generate` - generates proxy config for the cluster
5. `ipi-conf-gcd` chain:
   - `ipi-conf` - generates base install-config
   - `ipi-conf-telemetry` - configures telemetry
   - `ipi-conf-gcd-creds` - validates GCD credentials
   - `ipi-conf-gcp` - configures GCP-specific fields
   - `ipi-conf-gcp-osimage` - sets custom OS image (rhcos10)
   - `ipi-conf-gcp-zones` - configures availability zones
   - `ipi-install-monitoringpvc` - configures monitoring PVC
6. `ipi-install` - runs `openshift-install create cluster`

**Test:**
- `openshift-e2e-test` - runs conformance tests

**Post:**
- `gather-core-dump`, `gather-gcp-console`, `gather-must-gather`, etc.
- `ipi-deprovision-deprovision` - runs `openshift-install destroy cluster`
- `gcp-deprovision-bastionhost` - deletes bastion VM and firewall rules
- `gcp-deprovision-vpc` - deletes VPC, subnets, router, NAT

## Troubleshooting

### "Section [core] has no property [universe_domain]"

The gcloud version is too old. The step ref must use the `5.0`
upi-installer image which has gcloud 563+.

### "The project 'fedora-coreos-cloud' was not found"

GCD cannot access public GCP image projects. The bastion image must be
uploaded to the GCD project and `BASTION_IMAGE_PROJECT` set to
`eu0:openshift`.

### "NetworkInterface NicType can only be set to GVNIC"

The image was created without `--guest-os-features=GVNIC`. Delete and
recreate it with the GVNIC flag.

### "oauth2.apis-berlin-build0.goog: Name or service not known"

The GCD SA key has a `token_uri` pointing to
`oauth2.apis-berlin-build0.goog` which doesn't resolve as a hostname.
Setting `gcloud config set universe_domain` before authenticating
makes gcloud use the correct oauth2 endpoint instead of the one in
the key file.
