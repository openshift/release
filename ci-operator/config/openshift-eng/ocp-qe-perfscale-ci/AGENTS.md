# AI Agents for ocp-qe-perfscale-ci

This directory contains Claude Code subagent definitions for automating common tasks in the
ocp-qe-perfscale-ci repository.

## Available Agents

### create_node_density_heavy_jobs

**Purpose**: Automates creation of node-density-heavy test configurations for new OpenShift versions.

**Usage**:
```bash
# User: "Create node-density-heavy jobs for OCP 4.25"
# Claude: [Invokes create_node_density_heavy_jobs agent]
```

**What it does**:
1. Finds the previous version's configuration file
2. Copies and updates version references
3. Validates the generated file
4. Runs `make jobs` to generate Prow jobs

**Files created**:
- `openshift-eng-ocp-qe-perfscale-ci-main__<VERSION>-nightly-node-density-heavy.yaml`

**Tests included**: 8 tests covering AWS (IPSec, 1500ppn), GCP (FIPS), Azure (multi-arch), Baremetal (multi-arch, arm64), IBM Cloud, Nutanix

---

### create_control_plane_jobs

**Purpose**: Automates creation of control-plane test configurations for new OpenShift versions.

**Usage**:
```bash
# User: "Create control-plane jobs for OCP 4.25"
# Claude: [Invokes create_control_plane_jobs agent]
```

**What it does**:
1. Finds the previous version's control-plane configuration file
2. Copies and updates version references
3. Validates the generated file
4. Runs `make jobs` to generate Prow jobs

**Files created**:
- `openshift-eng-ocp-qe-perfscale-ci-main__<VERSION>-nightly-control-plane.yaml`

**Tests included**: Control plane scalability tests with 120+ node clusters, IPSec, UDN, etcd encryption

---

### create_loaded_upgrade_jobs

**Purpose**: Automates creation of AWS loaded upgrade test configurations for new OpenShift versions.

**Usage**:
```bash
# User: "Create loaded upgrade jobs for OCP 4.25"
# Claude: [Invokes create_loaded_upgrade_jobs agent]
```

**What it does**:
1. Finds the previous version's loaded upgrade configuration file
2. Creates upgrade tests FROM (version-1) TO version (e.g., 4.24 → 4.25)
3. Updates initial version bounds and target version
4. Validates the generated file
5. Runs `make jobs` to generate Prow jobs

**Files created**:
- `openshift-eng-ocp-qe-perfscale-ci-main__aws-<VERSION>-nightly-x86-loaded-upgrade-from-<PRIOR>.yaml`

**Tests included**: Upgrade performance tests under cluster-density workload on AWS

---

## Helper Scripts

All scripts are located in `scripts/`:

- `create_node_density_heavy_jobs.sh` - Creates node-density-heavy configs for a new version
- `create_control_plane_jobs.sh` - Creates control-plane configs for a new version
- `create_loaded_upgrade_jobs.sh` - Creates AWS loaded upgrade configs for a new version

## Creating All Configs at Once

You can run all three scripts manually to create a complete set of perfscale configs:

```bash
cd ci-operator/config/openshift-eng/ocp-qe-perfscale-ci

# Create all three config types for version 4.25
./scripts/create_node_density_heavy_jobs.sh 4.25
./scripts/create_control_plane_jobs.sh 4.25
./scripts/create_loaded_upgrade_jobs.sh 4.25
```

This creates:
- Node-density-heavy tests (8 tests, multiple platforms)
- Control-plane tests (120+ node scalability)
- Loaded upgrade tests (4.24 → 4.25 upgrade under load)

## Usage Pattern

1. User asks Claude to create configs for a new version
2. Claude recognizes the pattern and invokes the appropriate agent
3. Agent runs the helper script
4. Agent validates the output
5. Agent reports results to the user

## Important Notes

- **Memory Issues**: `make jobs` may fail locally with Error 137 (out of memory). This is normal - the YAML configs are valid and CI will generate Prow jobs when you create a PR.
- **Cron Schedules**: Review cron schedules in generated files to avoid conflicts with existing jobs.
- **Version Dependencies**: The loaded-upgrade script creates upgrade jobs FROM (target-1) TO target.
- **Validation**: All scripts validate YAML syntax before running make jobs.
- **Location**: All agents are in `agents/`, all scripts are in `scripts/`.
