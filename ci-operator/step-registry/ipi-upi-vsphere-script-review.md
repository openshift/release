# IPI/UPI vSphere Shell Script Review

## Scope

Full recursive review of all vsphere-related shell scripts under `ipi/` and `upi/`
directories of the step-registry. 53 scripts total: 35 under `ipi/`, 18 under `upi/`.

---

## Inventory Summary

| Area | Script Count | Total Lines | Avg Lines |
|------|-------------|-------------|-----------|
| `ipi/conf/vsphere/` | 25 | ~3,200 | 128 |
| `ipi/deprovision/vsphere/` | 8 | ~1,830 | 229 |
| `ipi/install/vsphere/` | 2 | 240 | 120 |
| `upi/conf/vsphere/` | 11 | ~3,500 | 318 |
| `upi/install/vsphere/` | 1 | 543 | 543 |
| `upi/deprovision/vsphere/` | 4 | 210 | 53 |
| `upi/vsphere/windows/` | 2 | 157 | 79 |
| **Total** | **53** | **~9,680** | **183** |

---

## Cross-Cutting Findings

These patterns appear across many scripts and should inform any simplification plan.

### 1. Already-Deprecated Scripts (annotated "no longer used")

Three scripts have explicit comments: **"This file is no longer used. It is being left behind temporarily while we migrate to python."**

| Script | Lines | Status |
|--------|-------|--------|
| `ipi/conf/vsphere/dns/ipi-conf-vsphere-dns-commands.sh` | 144 | Deprecated |
| `ipi/conf/vsphere/lb/external/ipi-conf-vsphere-lb-external-commands.sh` | 242 | Deprecated |
| `ipi/conf/vsphere/vips/vcm/ipi-conf-vsphere-vips-vcm-commands.sh` | 30 | Deprecated |
| `ipi/deprovision/vsphere/dns/ipi-deprovision-vsphere-dns-commands.sh` | 49 | Deprecated |

**Recommendation**: Remove these scripts once the Python replacements are confirmed active. No further review needed.

### 2. Massive Duplication Between Legacy and VCM Siblings

Many scripts exist in two forms: a legacy version and a VCM (vSphere Capacity Manager) version, where one immediately exits with `"using VCM sibling of this step"` or `"using legacy sibling of this step"`. The core logic between these sibling pairs is largely copy-pasted with minor differences in how context/credentials are sourced.

**High-duplication pairs**:

| Legacy Script | VCM Script | Shared Logic |
|---------------|-----------|-------------|
| `ipi-conf-vsphere-commands.sh` (315 lines) | `ipi-conf-vsphere-vcm-commands.sh` (399 lines) | ~85% identical: version detection, machine pool overrides, pull-through cache, install-config generation |
| `ipi-conf-vsphere-check-commands.sh` (181 lines) | `ipi-conf-vsphere-check-vcm-commands.sh` (695 lines) | Similar lease/network setup patterns, same VM cleanup logic |
| `ipi-deprovision-vsphere-diags-commands.sh` (596 lines) | `ipi-deprovision-vsphere-diags-vcm-commands.sh` (716 lines) | ~90% identical: metric lists, HTML generation, sosreport collection |
| `upi-conf-vsphere-commands.sh` (423 lines) | `upi-conf-vsphere-vcm-commands.sh` (726 lines) | ~70% identical: install-config, terraform.tfvars, variables.ps1 generation, manifest creation, ignition |
| `upi-conf-vsphere-ova-commands.sh` (150 lines) | `upi-conf-vsphere-ova-vcm-commands.sh` (155 lines) | ~85% identical: OVA download, network validation, hw version cloning |
| `ipi-conf-vsphere-vips-commands.sh` (37 lines) | `ipi-conf-vsphere-vips-vcm-commands.sh` (30 lines) | Same purpose, different JSON paths |

**Recommendation**: Consolidate each pair into a single script that branches on `CLUSTER_PROFILE_NAME`. This alone would eliminate ~1,500 lines.

### 3. Duplicated AWS CLI Installation Boilerplate

At least 7 scripts contain nearly identical ~20-line blocks to conditionally install the AWS CLI via pip2 or pip3:

- `ipi-conf-vsphere-dns-commands.sh`
- `ipi-conf-vsphere-lb-commands.sh`
- `ipi-deprovision-vsphere-dns-commands.sh`
- `ipi-deprovision-vsphere-lb-commands.sh`
- `upi-conf-vsphere-dns-commands.sh`
- `upi-conf-vsphere-clusterbot-pre-commands.sh`
- `upi-deprovision-vsphere-dns-commands.sh`

**Recommendation**: Extract to a shared utility script or ensure the CI image has AWS CLI pre-installed.

### 4. Duplicated OVA/Hardware Version Selection

The hardware version selection logic is copy-pasted across 5 scripts:

- `ipi-conf-vsphere-template-commands.sh`
- `upi-conf-vsphere-commands.sh`
- `upi-conf-vsphere-vcm-commands.sh`
- `upi-conf-vsphere-platform-external-commands.sh`
- `upi-conf-vsphere-zones-commands.sh`

Pattern: query `govc about -json`, determine vSphere 7 vs 8, build hw_versions array, random-select.

**Recommendation**: Extract to a shared function or a small utility script.

### 5. Duplicated DNS Record Generation (Route53)

At least 5 scripts independently build Route53 JSON for create/delete batch operations using the same jq patterns:

- `ipi-conf-vsphere-dns-commands.sh`
- `upi-conf-vsphere-commands.sh`
- `upi-conf-vsphere-vcm-commands.sh`
- `upi-conf-vsphere-platform-external-commands.sh`
- `upi-conf-vsphere-zones-commands.sh`

**Recommendation**: Strong candidate for a Python utility. JSON construction in bash is error-prone and hard to read. A small Python script could accept parameters and emit the Route53 batch JSON cleanly.

### 6. Duplicated Pull-Through Cache Logic

Three scripts contain identical ~30-line blocks for pull-through cache credential merging and config injection:

- `ipi-conf-vsphere-commands.sh`
- `ipi-conf-vsphere-vcm-commands.sh`
- `upi-conf-vsphere-vcm-commands.sh`

**Recommendation**: Extract to shared function.

---

## Per-Script Detailed Assessment

### IPI Configuration Scripts (`ipi/conf/vsphere/`)

#### `ipi-conf-vsphere-commands.sh` (315 lines)
**Purpose**: Generates `install-config.yaml` platform section for legacy (non-VCM) IPI.
**Complexity**: High. Version detection, dual config format (pre-4.13 vs 4.13+), machine pool overrides by size variant, pull-through cache credential merging via sed/jq.
**Simplification**:
- Consolidate with VCM sibling (saves ~300 lines).
- The install-config YAML generation via heredocs with embedded variables is fragile. **Python with a YAML library would be significantly more reliable** for this script.
- The pull-through cache `sed '/pullSecret/d'` pipeline is brittle and should use `yq` or Python.

#### `ipi-conf-vsphere-check-commands.sh` (181 lines)
**Purpose**: Parses LEASED_RESOURCE, sources credentials, generates govc.sh/vsphere_context.sh, cleans up stale VMs on portgroup.
**Complexity**: Medium.
**Simplification**: Minor. Well-structured. Quote unquoted variables.

#### `ipi-conf-vsphere-check-vcm-commands.sh` (695 lines)
**Purpose**: VCM version of the check step. Creates leases via `oc create`, waits for fulfillment, extracts topology, generates govc.sh files per pool, builds platform spec JSON, cleans up stale VMs.
**Complexity**: Very high. The most complex script in the set.
**Simplification**:
- **Strong candidate for Python rewrite**. This script builds complex JSON structures using repeated `jq` invocations, manages associative arrays, constructs YAML via a custom jq plugin (`yamlify2`), and orchestrates Kubernetes CRD operations. Python with the `kubernetes` client, `json`, and `yaml` libraries would be dramatically clearer.
- At minimum, extract the `getDVSInfo`, `getTypeInHeirarchy`, `getPortGroup`, and `networkToSubnetsJson` functions into a shared library or Python module.
- The lease creation YAML embedded in `echo | oc create` is a maintenance hazard.

#### `ipi-conf-vsphere-customized-resource-commands.sh` (36 lines)
**Purpose**: Patches install-config with custom CPU/memory/disk.
**Simplification**: Already simple. No changes needed.

#### `ipi-conf-vsphere-disktype-commands.sh` (20 lines)
**Purpose**: Patches install-config with disk type.
**Simplification**: Already minimal. No changes needed.

#### `ipi-conf-vsphere-dns-commands.sh` (144 lines)
**Purpose**: Creates Route53 DNS records for API/Ingress VIPs.
**Simplification**: **Already deprecated** (header comment). Remove once Python replacement confirmed.

#### `ipi-conf-vsphere-folder-commands.sh` (52 lines)
**Purpose**: Creates vSphere folder and patches install-config.
**Simplification**: Already clean and short. No changes needed.

#### `ipi-conf-vsphere-lb-commands.sh` (123 lines)
**Purpose**: Creates AWS NLB, target groups, and listeners for clusterbot launch jobs.
**Complexity**: Medium. Linear AWS CLI calls.
**Simplification**: The script has a comment `"no more VMC....should we just delete this??????"`. **Investigate if this is still needed.**

#### `ipi-conf-vsphere-lb-external-commands.sh` (242 lines)
**Purpose**: Deploys a CoreOS-based HAProxy load balancer VM using govc.
**Simplification**: **Already deprecated** (header comment). Remove once Python replacement confirmed. If not deprecated, this is a good Python candidate due to complex Butane config generation.

#### `ipi-conf-vsphere-minimal-permission-commands.sh` (44 lines)
**Purpose**: Patches install-config with minimal-permission vCenter credentials.
**Simplification**: Already simple. No changes needed.

#### `ipi-conf-vsphere-multi-vcenter-commands.sh` (117 lines)
**Purpose**: Generates install-config for multi-vCenter environments.
**Complexity**: Medium. Multiple heredoc appends with jq-extracted values.
**Simplification**: Moderate candidate for Python/yq. The repeated `echo $fd | jq -r '.field'` pattern inside a heredoc is hard to maintain.

#### `ipi-conf-vsphere-nmdebug-commands.sh` (35 lines)
**Purpose**: Adds NetworkManager debug MachineConfig manifest.
**Simplification**: Already minimal. No changes needed.

#### `ipi-conf-vsphere-proxy-commands.sh` (15 lines)
**Purpose**: Appends proxy config to install-config.
**Simplification**: Already minimal.

#### `ipi-conf-vsphere-proxy-https-commands.sh` (20 lines)
**Purpose**: Appends HTTPS proxy config with additional CA bundle.
**Simplification**: Already minimal.

#### `ipi-conf-vsphere-staticip-commands.sh` (94 lines)
**Purpose**: Generates static IP host entries for install-config.
**Complexity**: Medium. Loop-based jq extraction.
**Simplification**: Minor. Could use a function to reduce loop duplication between bootstrap/control-plane/compute blocks.

#### `ipi-conf-vsphere-staticip-verify-commands.sh` (135 lines)
**Purpose**: Installs IPPools CRD, configures IPAM controller, scales machineset, validates static IPs.
**Complexity**: Medium-high. Long polling loop with node validation.
**Simplification**: The validation loop (lines 93-132) is complex but functional. Minor cleanup only.

#### `ipi-conf-vsphere-template-commands.sh` (52 lines)
**Purpose**: Selects RHCOS template and hw version, patches install-config.
**Simplification**: Already clean. Extract hw version selection to shared function (duplicated in 5 places).

#### `ipi-conf-vsphere-usertags-commands.sh` (19 lines)
**Purpose**: Patches install-config with user tags.
**Simplification**: Already minimal.

#### `ipi-conf-vsphere-vcm-commands.sh` (399 lines)
**Purpose**: VCM sibling of `ipi-conf-vsphere-commands.sh`.
**Simplification**: Consolidate with legacy sibling. See cross-cutting finding #2.

#### `ipi-conf-vsphere-vips-commands.sh` (37 lines)
**Purpose**: Extracts API/Ingress VIPs from subnets.json.
**Simplification**: Already simple. Consolidate with VCM sibling.

#### `ipi-conf-vsphere-vips-vcm-commands.sh` (30 lines)
**Purpose**: VCM version of VIP extraction.
**Simplification**: **Already deprecated**. Remove.

#### `ipi-conf-vsphere-windows-machineset-commands.sh` (44 lines)
**Purpose**: Creates Windows worker machineset from Linux machineset template.
**Simplification**: Already clean. No changes needed.

#### `ipi-conf-vsphere-zones-commands.sh` (152 lines)
**Purpose**: Generates zonal install-config with hardcoded failure domains.
**Complexity**: Medium. Hardcoded topology (datacenter names, cluster names, datastore names).
**Simplification**: The hardcoded topology should be data-driven. Not a bash vs Python issue, but a config issue.

#### `ipi-conf-vsphere-zones-customize-commands.sh` (58 lines)
**Purpose**: Patches install-config with custom zone assignments.
**Simplification**: Already clean. No changes needed.

#### `ipi-conf-vsphere-zones-multisubnets-commands.sh` (31 lines)
**Purpose**: Patches install-config for UserManaged LB with multi-subnet zones.
**Simplification**: Already minimal.

### IPI Deprovision Scripts (`ipi/deprovision/vsphere/`)

#### `ipi-deprovision-vsphere-diags-commands.sh` (596 lines)
**Purpose**: Collects vCenter performance metrics, alerts, console screenshots, and generates an HTML dashboard with embedded Chart.js graphs.
**Complexity**: Very high. Mixes bash (govc metric collection, SSH sosreports) with inline HTML/CSS/JavaScript (Vue.js app, Chart.js graphs).
**Simplification**:
- **Strong candidate for partial Python rewrite**. The metric collection (govc calls) should stay as bash, but the HTML generation (~350 lines of inline HTML/JS) should be a separate template file or Python-generated HTML.
- The HTML is duplicated almost entirely in `ipi-deprovision-vsphere-diags-vcm-commands.sh`.
- Extract HTML template to a file and use a simple templating approach.

#### `ipi-deprovision-vsphere-diags-vcm-commands.sh` (716 lines)
**Purpose**: VCM version of diagnostics collection. Adds multi-vCenter support and VM screenshots.
**Simplification**: Consolidate with legacy sibling. ~90% identical HTML/JS code.

#### `ipi-deprovision-vsphere-dns-commands.sh` (49 lines)
**Purpose**: Deletes Route53 DNS records.
**Simplification**: **Already deprecated**. Remove.

#### `ipi-deprovision-vsphere-folder-commands.sh` (24 lines)
**Purpose**: Deletes vSphere folder.
**Simplification**: Already minimal.

#### `ipi-deprovision-vsphere-lb-commands.sh` (58 lines)
**Purpose**: Deletes AWS NLB and target groups.
**Simplification**: Already clean. Same question as its creation counterpart: is this still needed?

#### `ipi-deprovision-vsphere-lb-external-commands.sh` (37 lines)
**Purpose**: Destroys external LB VM.
**Simplification**: Already simple. Make `govc vm.power -off` best-effort.

#### `ipi-deprovision-vsphere-lease-commands.sh` (17 lines)
**Purpose**: Deletes VCM leases.
**Simplification**: Already minimal.

#### `ipi-deprovision-vsphere-virt-commands.sh` (37 lines)
**Purpose**: Tears down KubeVirt VMs for hybrid vSphere+BM testing.
**Simplification**: Already clean.

### IPI Install Scripts (`ipi/install/vsphere/`)

#### `ipi-install-vsphere-registry-commands.sh` (47 lines)
**Purpose**: Configures image registry (PVC or emptyDir).
**Simplification**: Already clean.

#### `ipi-install-vsphere-virt-commands.sh` (193 lines)
**Purpose**: Creates KubeVirt VMs as bare-metal nodes, approves CSRs, manages storage operator.
**Complexity**: Medium-high. Multiple sequential operations with polling loops.
**Simplification**: Well-structured with helper functions. Minor improvements only.

### UPI Configuration Scripts (`upi/conf/vsphere/`)

#### `upi-conf-vsphere-commands.sh` (423 lines)
**Purpose**: Full UPI setup: install-config, manifests, ignition, terraform.tfvars, variables.ps1.
**Complexity**: High. Generates 4 different config file formats (YAML, HCL, PowerShell, JSON).
**Simplification**:
- **Good candidate for Python rewrite** for the multi-format config generation portion. Generating HCL (`terraform.tfvars`), PowerShell (`variables.ps1`), and YAML (`install-config.yaml`) from the same data in bash is error-prone.
- Consolidate with VCM sibling.

#### `upi-conf-vsphere-vcm-commands.sh` (726 lines)
**Purpose**: VCM version of UPI setup. Adds failure domain detection, DVS UUID lookup, pull-through cache.
**Complexity**: Very high. The longest UPI script.
**Simplification**: Consolidate with legacy sibling. The `getFailureDomainsWithDSwitch` function is complex but well-isolated.

#### `upi-conf-vsphere-clusterbot-pre-commands.sh` (187 lines)
**Purpose**: Creates AWS NLB and Route53 DNS records for clusterbot UPI launches.
**Simplification**: Contains duplicated AWS CLI install and NLB creation boilerplate. Factor out shared code.

#### `upi-conf-vsphere-dns-commands.sh` (153 lines)
**Purpose**: Creates Route53 DNS records for UPI clusters.
**Simplification**: Duplicated AWS CLI install boilerplate. Otherwise clean.

#### `upi-conf-vsphere-ova-commands.sh` (150 lines)
**Purpose**: Downloads and imports RHCOS OVA, creates hw-versioned clones.
**Complexity**: Medium. Network validation logic for distributed port groups.
**Simplification**: Consolidate with VCM sibling. Extract network validation to shared function.

#### `upi-conf-vsphere-ova-vcm-commands.sh` (155 lines)
**Purpose**: VCM version of OVA import.
**Simplification**: ~85% identical to legacy sibling. Consolidate.

#### `upi-conf-vsphere-ova-windows-commands.sh` (34 lines)
**Purpose**: Validates Windows VM template exists in vCenter.
**Simplification**: Already minimal.

#### `upi-conf-vsphere-platform-external-commands.sh` (790 lines)
**Purpose**: Full UPI setup for platform External (vSphere CCM). Generates install-config, manifests, CCM DaemonSet, CSI driver config, ignition.
**Complexity**: Very high. The longest single script. ~350 lines are inline Kubernetes YAML manifests.
**Simplification**:
- **Strong candidate for restructuring**. The inline YAML manifests (CCM namespace, SA, secret, configmap, RBAC, DaemonSet, CSI driver config) should be external template files, not heredocs in a shell script.
- The config generation logic duplicates `upi-conf-vsphere-commands.sh`.

#### `upi-conf-vsphere-platform-none-commands.sh` (32 lines)
**Purpose**: Appends platform none/external config to install-config.
**Simplification**: Already minimal.

#### `upi-conf-vsphere-tcpdump-commands.sh` (116 lines)
**Purpose**: Deploys a tcpdump DaemonSet for network debugging.
**Simplification**: Clean. The inline DaemonSet YAML could be an external file but it's manageable at this size.

#### `upi-conf-vsphere-zones-commands.sh` (516 lines)
**Purpose**: Full UPI setup for zonal installations. Hardcoded failure domains.
**Complexity**: High. Duplicates most of `upi-conf-vsphere-commands.sh` plus zonal topology.
**Simplification**: ~60% of this script is shared with `upi-conf-vsphere-commands.sh`. Extract common logic.

### UPI Install Scripts (`upi/install/vsphere/`)

#### `upi-install-vsphere-commands.sh` (543 lines)
**Purpose**: Runs terraform/PowerCLI to provision VMs, monitors bootstrap/install completion, approves CSRs, configures image registry.
**Complexity**: Very high. Multi-vCenter VM discovery, bootstrap log gathering, terraform state management, CSR approval loop.
**Simplification**:
- The `gather_console_and_bootstrap` function (lines 70-332) is 260 lines and handles both legacy single-lease and new multi-pool lease patterns. This would benefit from Python for the JSON/lease file processing.
- The rest (terraform/pwsh orchestration, CSR approval) is well-suited to bash.

### UPI Deprovision Scripts (`upi/deprovision/vsphere/`)

#### `upi-deprovision-vsphere-commands.sh` (98 lines)
**Purpose**: Collects diagnostics, runs terraform destroy or PowerCLI upi-destroy.
**Simplification**: Already reasonable. Minor quoting fixes.

#### `upi-deprovision-vsphere-dns-commands.sh` (52 lines)
**Purpose**: Deletes Route53 DNS records for UPI clusters.
**Simplification**: Duplicated AWS CLI install. Otherwise clean.

#### `upi-deprovision-vsphere-external-diags-commands.sh` (27 lines)
**Purpose**: Runs `oc adm inspect` for external platform namespaces.
**Simplification**: Already minimal.

#### `upi-deprovision-vsphere-workers-rhel-commands.sh` (33 lines)
**Purpose**: Powers off and destroys RHEL worker VMs, deletes DNS records.
**Simplification**: Already minimal. Make `govc vm.power/destroy` best-effort.

### UPI Windows Scripts (`upi/vsphere/windows/`)

#### `upi-vsphere-windows-pre-commands.sh` (118 lines)
**Purpose**: Provisions Windows VMs via govc clone.
**Simplification**: Parameterize hardcoded VM specs (CPU=4, memory=16384, disk=128GB). Remove unnecessary `sleep 60`. Fix unquoted variables.

#### `upi-vsphere-windows-post-commands.sh` (39 lines)
**Purpose**: Destroys Windows VMs.
**Simplification**: Make teardown best-effort. Add `shopt -s nullglob`.

---

## Priority Recommendations

### Tier 1: High Impact, Lower Risk

| Action | Scripts Affected | Lines Saved | Effort |
|--------|-----------------|-------------|--------|
| Remove 4 deprecated scripts | 4 | ~465 | Low |
| Consolidate legacy/VCM sibling pairs | 12 (6 pairs) | ~1,500 | Medium |
| Extract shared AWS CLI install function | 7 | ~140 | Low |
| Extract shared hw version selection function | 5 | ~60 | Low |

### Tier 2: Moderate Impact, Medium Risk

| Action | Scripts Affected | Benefit | Effort |
|--------|-----------------|---------|--------|
| Extract pull-through cache logic to shared function | 3 | DRY, maintainability | Low |
| Externalize HTML/JS template from diags scripts | 2 | ~700 lines cleaner, easier to maintain | Medium |
| Externalize Kubernetes YAML manifests from platform-external script | 1 | ~350 lines of manifests out of shell | Medium |
| Extract common UPI config generation (install-config, terraform.tfvars, variables.ps1) | 3 | ~400 lines DRY | Medium-High |

### Tier 3: High Impact, Higher Risk (Python Rewrites)

| Action | Scripts | Why Python | Effort |
|--------|---------|-----------|--------|
| Rewrite `ipi-conf-vsphere-check-vcm-commands.sh` | 1 (695 lines) | Complex JSON construction, K8s CRD management, associative arrays, custom jq YAML converter. Python with `kubernetes` client + `json` + `yaml` libraries would be dramatically more maintainable. | High |
| Rewrite install-config generation portion of `ipi-conf-vsphere-commands.sh` + VCM sibling | 2 (~714 lines combined) | YAML construction via heredocs is fragile. Python `yaml.dump()` would eliminate quoting/indentation bugs. | Medium-High |
| Rewrite DNS/Route53 JSON generation | 5 scripts | JSON construction in bash via repeated `jq` piping is hard to read and maintain. | Medium |
| Rewrite UPI multi-format config generation | 3 scripts | Generating HCL, PowerShell, and YAML from the same data set in bash is inherently fragile. | High |

### Tier 4: Leave As-Is

The following scripts are short, clean, and well-suited to bash. No changes recommended:

- `ipi-conf-vsphere-customized-resource-commands.sh` (36 lines)
- `ipi-conf-vsphere-disktype-commands.sh` (20 lines)
- `ipi-conf-vsphere-folder-commands.sh` (52 lines)
- `ipi-conf-vsphere-minimal-permission-commands.sh` (44 lines)
- `ipi-conf-vsphere-nmdebug-commands.sh` (35 lines)
- `ipi-conf-vsphere-proxy-commands.sh` (15 lines)
- `ipi-conf-vsphere-proxy-https-commands.sh` (20 lines)
- `ipi-conf-vsphere-usertags-commands.sh` (19 lines)
- `ipi-conf-vsphere-windows-machineset-commands.sh` (44 lines)
- `ipi-conf-vsphere-zones-customize-commands.sh` (58 lines)
- `ipi-conf-vsphere-zones-multisubnets-commands.sh` (31 lines)
- `ipi-deprovision-vsphere-folder-commands.sh` (24 lines)
- `ipi-deprovision-vsphere-lb-external-commands.sh` (37 lines)
- `ipi-deprovision-vsphere-lease-commands.sh` (17 lines)
- `ipi-deprovision-vsphere-virt-commands.sh` (37 lines)
- `ipi-install-vsphere-registry-commands.sh` (47 lines)
- `upi-conf-vsphere-ova-windows-commands.sh` (34 lines)
- `upi-conf-vsphere-platform-none-commands.sh` (32 lines)
- `upi-deprovision-vsphere-external-diags-commands.sh` (27 lines)
- `upi-deprovision-vsphere-workers-rhel-commands.sh` (33 lines)

---

## Summary

| Category | Count | Total Lines |
|----------|-------|-------------|
| Remove (deprecated) | 4 | ~465 |
| Consolidate (sibling pairs) | 12 | ~1,500 savings |
| Rewrite to Python (recommended) | 2-3 | ~1,400 |
| Extract shared functions | ~20 affected | ~400 savings |
| Leave as-is | 20 | ~700 |
| Minor bash fixes only | ~15 | ~5,200 |

The biggest wins come from **consolidating legacy/VCM sibling pairs** (mechanical, low-risk) and **rewriting the check-vcm and install-config generation scripts to Python** (higher effort but addresses real maintainability problems). The scripts that construct complex JSON, YAML, or multi-format config files are the strongest Python candidates. Scripts that are thin wrappers around CLI tools (govc, oc, terraform, aws) should remain in bash.
