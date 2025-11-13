# sandboxed-containers-operator-trustee-install

## Purpose

Installs and configures the Trustee Operator for Confidential Containers (CoCo). This step is part of the `sandboxed-containers-operator-pre` chain and should run after the `sandboxed-containers-operator-env-cm` step creates the `osc-config` ConfigMap.

## Requirements

- OpenShift cluster with admin access
- The `osc-config` ConfigMap should be created by the `sandboxed-containers-operator-env-cm` step
- The cluster should have access to the operator catalog containing the Trustee Operator

## What This Step Does

This step performs the following operations:

1. **Subscribes to the Trustee Operator**: Creates a subscription to install the Trustee Operator from the specified catalog source
2. **Creates Secrets**:
   - `kbs-auth-public-key` - Authentication public key for KBS
   - `attestation-token` - SSL/TLS certificate and key for attestation
   - `kbs-https-certificate` and `kbs-https-key` - HTTPS certificates for the KBS service
   - `kbsres1` - Example resource secret for clients
   - `cosign-public-key` - Container image signature verification key
   - `security-policy` - Container security policy configuration
3. **Creates ConfigMaps**:
   - `kbs-config-cm` - Trustee service configuration
   - `rvps-reference-values` - Reference Value Provider Service configuration
   - `attestation-policy` - OPA attestation policy
   - `resource-policy` - Resource access policy (permissive for testing or restrictive for production)
   - `tdx-config` - Intel TDX configuration (optional)
4. **Configures KBS**: Creates and applies the `KbsConfig` custom resource
5. **Generates INITDATA**: Creates the INITDATA configuration for peer pods and saves it to `${SHARED_DIR}/initdata_string.txt`
6. **Creates Route**: Exposes the KBS service externally

## Configuration

The step accepts several environment variables:

- `INSTALL_TRUSTEE` - Enable/disable trustee installation (default: `false`). Set to `true` to enable. **Required for CoCo (Confidential Containers) workloads**
- `TRUSTEE_CATALOG_SOURCE_NAME` - Catalog source for the Trustee Operator. If not set, it will use the value from `osc-config` ConfigMap (created by `env-cm` step), or default to `redhat-operators`
- `TRUSTEE_URL_USE_HTTP` - Set to `true` to use HTTP instead of HTTPS (insecure - for testing only). Default: `false`
- `TRUSTEE_URL_USE_NODEPORT` - Set to `true` to use nodeIP:nodePort instead of route hostname. Default: `false`
- `TRUSTEE_INSECURE_HTTP` - Set to `true` to enable insecure HTTP in KBS config. Default: `false`
- `TRUSTEE_TESTING` - Set to `true` to use permissive resource policy for development/testing. Default: `false`
- `TRUSTEE_ORG` - Organization (O) value in certificates. Default: `Red Hat OpenShift`
- `TRUSTEE_CN` - Common Name (CN) value in certificates. Default: `kbs-trustee-operator-system`

## Outputs

- Creates all necessary resources in the `trustee-operator-system` namespace
- Saves `INITDATA_STRING` to `${SHARED_DIR}/initdata_string.txt` for use by subsequent steps
- Exports `TRUSTEE_URL` environment variable
- Generates a `patch_peer_pods_cm.sh` script for updating the peer-pods-cm ConfigMap

## Usage Example

### As Part of Prow Workflow

This step is automatically included in the `sandboxed-containers-operator-pre` chain and runs after the `sandboxed-containers-operator-env-cm` step.

To use it in a workflow:

```yaml
workflow:
  steps:
    pre:
      - chain: sandboxed-containers-operator-pre
```

To configure it with custom settings:

```yaml
workflow:
  steps:
    pre:
      - chain: sandboxed-containers-operator-pre
    env:
      INSTALL_TRUSTEE: "true"
      TRUSTEE_TESTING: "true"
      TRUSTEE_INSECURE_HTTP: "true"
```

### Standalone Execution

The script can be run standalone outside of a prow environment. Simply execute it directly:

```bash
# Basic usage - Note: INSTALL_TRUSTEE defaults to false, so you must set it to true
INSTALL_TRUSTEE=true ./sandboxed-containers-operator-trustee-install-commands.sh

# With custom settings
INSTALL_TRUSTEE=true \
TRUSTEE_TESTING=true \
TRUSTEE_INSECURE_HTTP=true \
TRUSTEE_CATALOG_SOURCE_NAME=my-catalog \
./sandboxed-containers-operator-trustee-install-commands.sh
```

When running standalone:
- **Important**: `INSTALL_TRUSTEE` defaults to `false`. You must set it to `true` to enable installation
- All other environment variables are optional and have sensible defaults
- If `SHARED_DIR` is not set, outputs are saved to the current directory
- The script will attempt to read `CATALOG_SOURCE_NAME` from the `osc-config` ConfigMap if available
- Requires `oc` CLI access to an OpenShift cluster with admin privileges

## Integration with Other Steps

- **Runs after**: `sandboxed-containers-operator-env-cm` (requires the `osc-config` ConfigMap)
- **Outputs for**: Subsequent steps that need to configure peer pods with Trustee connectivity
- **Part of**: `sandboxed-containers-operator-pre` chain

## Notes

- The step creates self-signed certificates for demonstration purposes. In production, you should use properly signed certificates.
- The RVPS reference values are initially empty and need to be populated with actual PCR measurements from your workloads.
- The attestation policy checks PCR values 03, 08, 09, 11, and 12 for Azure vTPM configurations.
- When `TRUSTEE_TESTING=true`, a permissive resource policy is used which allows all resource requests. This should only be used for testing.

## Troubleshooting

If the step fails:

1. Check that the Trustee Operator catalog source is available:
   ```bash
   oc get catalogsource -n openshift-marketplace
   ```

2. Check the trustee-operator subscription status:
   ```bash
   oc get subscription trustee-operator -n trustee-operator-system
   ```

3. Check the CSV installation:
   ```bash
   oc get csv -n trustee-operator-system
   ```

4. Check the KBS service and route:
   ```bash
   oc get service,route -n trustee-operator-system
   ```

5. View the step logs for detailed error messages
