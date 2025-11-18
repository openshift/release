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

## Slash Commands

This repository includes custom slash commands to improve productivity:

### `/step-finder` - Component Discovery
Search the step-registry (4,400+ reusable CI components) to find existing steps, workflows, and chains before creating new ones:

```bash
/step-finder aws upgrade workflow          # Find AWS upgrade workflows
/step-finder install operator step yes     # Find operator installation steps with usage examples
```

**Always use `/step-finder` before creating new step-registry components to avoid duplication.**

See `.claude/SLASH_COMMANDS.md` for detailed documentation.

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
- `ci-operator/config/`: `<org>-<repo>-<branch>__periodics.yaml` (variant periodic config)
- `ci-operator/jobs/`: `<org>-<repo>-<org>-<repo>-<branch>-<jobtype>.yaml`
- `step-registry/`: Component name prefixed (e.g., `openshift-e2e-test-ref.yaml`)
- `core-services/`: `admin_*.yaml` for admin resources, `_*.yaml` excluded from application

### Variant Periodic Configuration Pattern
Periodic tests can be separated from main configuration into dedicated `__periodics.yaml` files:
- Keeps main config files focused on presubmit/postsubmit tests
- Example: `openshift-cluster-authentication-operator-release-4.21__periodics.yaml`
- Contains only periodic tests with `interval:` scheduling
- Uses `variant: periodics` in `zz_generated_metadata`
- Generated jobs go to separate `-periodics.yaml` files in `ci-operator/jobs/`

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

### Creating Variant Periodic Configurations
For repositories with many periodic tests, separate them from the main config:
1. Create `ci-operator/config/<org>/<repo>/<org>-<repo>-<branch>__periodics.yaml`
2. Include `base_images`, `build_root`, `images`, `promotion`, `releases` sections (copy from main config)
3. Add only `tests:` entries with `interval:` (periodic scheduling)
4. Ensure `zz_generated_metadata` has `variant: periodics`
5. Run `make jobs` to generate Prow jobs in separate `-periodics.yaml` file
6. This pattern keeps main config focused on PR/postsubmit jobs while isolating scheduled tests

## OpenShift Release Versioning

### Release Branches
OpenShift uses semantic versioning with minor releases (4.18, 4.19, 4.20, 4.21, 4.22, etc.):
- **Branch names**: `release-4.21`, `release-4.20`, etc. (or `main`/`master`)
- **Config files**: One per branch per repository (e.g., `openshift-oauth-server-release-4.21.yaml`)
- **Release cycle**: New minor versions branch quarterly

### Config Brancher Tool
The `config-brancher` tool automates creating CI configs for new releases:
```bash
# Example from recent commits
config-brancher --config-dir ./ci-operator/config --current-release 4.21 --future-release 4.22 --confirm
```
This copies configs from current to future release, updating version references.

Use `--skip-periodics` to avoid branching periodic jobs (they're often managed separately in `__periodics.yaml` files).

## Python Environment Setup

If Python scripts fail (e.g., `generate-release-controllers.py`), set up a virtual environment:
```bash
python3 -m venv venv/           # First time only
source venv/bin/activate
python3 -m pip install pyyaml
# Run your Python commands...
deactivate                      # When done
```

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
