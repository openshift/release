# Opt-In and Opt-Out File Format

Both opt-in and opt-out files use the same YAML format:

```yaml
organization_name:
  - repo1
  - repo2
  - repo3
another_organization:
  - repo4
  - repo5
```

### Structure
- **Top level**: Organization names (GitHub organization)
- **Second level**: List of repository names within that organization
- **Result**: Repositories are internally represented as `org/repo` format

## Example Files

### Opt-In File (`opt-in.yaml`)

```yaml
openshift:
  - cluster-api-provider-aws
  - cluster-api-provider-azure
  - cluster-api-provider-gcp
  - installer
  - machine-config-operator
  - cluster-node-tuning-operator
  - oauth-proxy
  - oc

openshift-priv:
  - security-scanner
  - vulnerability-tools

```

### Opt-Out File (`opt-out.yaml`)

```yaml
openshift:
  - legacy-installer
  - deprecated-monitoring
  - experimental-features
  - test-only-repo

openshift-priv:
  - excluded-security-repo

```

### Empty Files

Empty files are valid and supported:

```yaml
# This file intentionally left empty
```

Or completely empty files (no content at all).
