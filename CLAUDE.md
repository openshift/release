# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This repository holds OpenShift cluster manifests, component build manifests and CI workflow configuration for OpenShift component repositories for both OKD and OCP.

## Repository Structure

- `ci-operator/config/` - CI configuration files defining builds and tests for component repositories
- `ci-operator/jobs/` - Generated Prow job configurations (auto-generated, rarely edited manually)
- `ci-operator/step-registry/` - Reusable test steps, chains, and workflows for multi-stage jobs
- `ci-operator/templates/` - Legacy black-box test workflows (deprecated, use step-registry instead)
- `core-services/` - Core service configurations applied to api.ci cluster
- `services/` - Additional service configurations
- `cluster/` - Legacy cluster provisioning manifests
- `projects/` - Experimental, legacy, or non-critical service manifests
- `tools/` - Container image build manifests for tooling

## Common Development Commands

### Configuration Updates
After modifying CI configuration files, regenerate downstream artifacts:
```bash
make update
```
This runs: `make jobs`, `make ci-operator-config`, `make prow-config`, `make registry-metadata`, `make release-controllers`, `make boskos-config`

### CI Job Configuration
When modifying CI jobs in `ci-operator/config/`:
```bash
make jobs
```
This validates config, generates Prow job configs, and sanitizes job definitions.

### Validation
```bash
make check              # Validate all service configs
make check-core         # Validate core-services
make check-services     # Validate services
make checkconfig        # Validate Prow configuration
```

### New Repository Setup
```bash
make new-repo
```
Interactive tool to configure CI workflow for a new component repository. Automatically runs `make update` afterwards.

### Step Registry Validation
```bash
make validate-step-registry
```
Validates step registry definitions for correctness.

### Release Controllers
```bash
make release-controllers
```
Regenerates release controller configurations.

## Architecture

### CI Operator Configuration Flow
1. Developers edit YAML files in `ci-operator/config/<org>/<repo>/`
2. Each config file defines:
   - `build_root`: Base image for builds
   - `images`: Container images to build
   - `tests`: Test definitions (can reference step-registry workflows)
   - `promotion`: Where to push successful builds
   - `releases`: OpenShift releases to test against
3. Running `make jobs` generates Prow job configs in `ci-operator/jobs/`
4. Prow triggers jobs based on PR/merge/periodic events
5. Jobs execute ci-operator with the config, which orchestrates builds and tests

### Step Registry System
The step-registry contains reusable CI components:
- **Steps** (`.yaml` + `-commands.sh`): Atomic tasks (e.g., `openshift-e2e-test`)
- **Chains** (`-chain.yaml`): Ordered sequences of steps
- **Workflows** (`-workflow.yaml`): Complete test scenarios with pre/test/post phases
- **References** (`-ref.yaml`): Step definitions with metadata

Steps are referenced in `ci-operator/config/` test definitions using multi-stage syntax. The registry allows sharing common operations (cluster provisioning, testing, cleanup) across many repositories.

### Configuration Generation Pipeline
1. `ci-operator/config/` is the source of truth (manually edited)
2. `ci-operator-prowgen` generates `ci-operator/jobs/` from config files
3. `determinize-ci-operator` normalizes config file formatting
4. `determinize-prow-config` normalizes Prow configuration
5. All generation uses containerized tools (pulled from quay.io/openshift/ci-public)

### File Naming Conventions
- `ci-operator/config/`: `<org>-<repo>-<branch>.yaml`
- `ci-operator/jobs/`: `<org>-<repo>-<org>-<repo>-<branch>-<jobtype>.yaml`
- `step-registry/`: Component name prefixed (e.g., `openshift-e2e-test-ref.yaml`)
- `core-services/`: `admin_*.yaml` for admin resources, `_*.yaml` excluded from application

## Key Workflows

### Modifying CI for a Repository
1. Edit config in `ci-operator/config/<org>/<repo>/`
2. Run `make jobs` to regenerate Prow jobs
3. Run `make checkconfig` to validate
4. Commit both config and generated job files

### Adding a New Test Step
1. Create files in `ci-operator/step-registry/<component>/`:
   - `<name>-ref.yaml` (step metadata)
   - `<name>-commands.sh` (script to execute)
2. Run `make registry-metadata` to update metadata
3. Reference the step in workflow chains or directly in configs

### Creating a New Workflow
1. Define individual steps if needed
2. Create a workflow file: `<name>-workflow.yaml`
3. Define `pre`, `test`, and `post` phases using existing steps/chains
4. Run `make validate-step-registry` to check correctness

## Container Engine
By default, `podman` is used. Override with:
```bash
export CONTAINER_ENGINE=docker
```

## Important Notes
- Never manually edit files in `ci-operator/jobs/` - always edit `ci-operator/config/` and regenerate
- New test workflows should use step-registry, not templates (templates are legacy)
- Core services config in `core-services/` is auto-applied by Prow postsubmit after merge
- ConfigMaps are updated by the `config-updater` Prow plugin
- The repository uses containerized tooling for most operations (check Makefile for specific images)
- Config files are deterministically formatted - manual formatting will be overwritten by generation tools
