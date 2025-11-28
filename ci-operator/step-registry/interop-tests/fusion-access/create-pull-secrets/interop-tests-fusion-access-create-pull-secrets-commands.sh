#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"
IBM_REGISTRY="${IBM_REGISTRY:-cp.icr.io}"
STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_DNS_NAMESPACE="${STORAGE_SCALE_DNS_NAMESPACE:-ibm-spectrum-scale-dns}"
STORAGE_SCALE_CSI_NAMESPACE="${STORAGE_SCALE_CSI_NAMESPACE:-ibm-spectrum-scale-csi}"
STORAGE_SCALE_OPERATOR_NAMESPACE="${STORAGE_SCALE_OPERATOR_NAMESPACE:-ibm-spectrum-scale-operator}"

# Credential paths
IBM_ENTITLEMENT_KEY_PATH="/var/run/secrets/ibm-entitlement-key"
FUSION_PULL_SECRET_EXTRA_PATH="/var/run/secrets/fusion-pullsecret-extra"

echo "🚀 Creating Fusion Access pull secrets..."
echo "Primary Namespace: $FUSION_ACCESS_NAMESPACE"
echo "IBM Registry: $IBM_REGISTRY"
echo ""
echo "IBM Storage Scale Namespaces:"
echo "  - ${STORAGE_SCALE_NAMESPACE}"
echo "  - ${STORAGE_SCALE_DNS_NAMESPACE}"
echo "  - ${STORAGE_SCALE_CSI_NAMESPACE}"
echo "  - ${STORAGE_SCALE_OPERATOR_NAMESPACE}"
echo ""

# Check if namespace exists
if ! oc get namespace "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "❌ ERROR: Namespace ${FUSION_ACCESS_NAMESPACE} does not exist"
  echo "Please ensure the namespace creation step runs before this step"
  exit 1
fi

echo "✅ Namespace ${FUSION_ACCESS_NAMESPACE} exists"

# Debug: Show what credential files are actually mounted
echo ""
echo "🔍 === DEBUGGING CREDENTIAL MOUNTS ==="
echo "Checking credential mount at: /var/run/secrets/"
echo ""

if [ -d "/var/run/secrets" ]; then
  echo "✅ Mount directory exists: /var/run/secrets/"
  echo ""
  echo "Files found in credential mount:"
  ls -la /var/run/secrets/ 2>&1 | head -20 || echo "  Cannot list directory contents"
  echo ""
  echo "Checking for specific credential files:"
  for file in "ibm-entitlement-key" "fusion-pullsecret-extra"; do
    if [ -f "/var/run/secrets/$file" ] || [ -L "/var/run/secrets/$file" ]; then
      size=$(stat -c%s "/var/run/secrets/$file" 2>/dev/null || echo "unknown")
      echo "  ✅ $file (${size} bytes)"
    else
      echo "  ❌ $file (not found)"
    fi
  done
  echo ""
else
  echo "❌ Mount directory DOES NOT EXIST: /var/run/secrets/"
  echo ""
fi

echo "=== END DEBUGGING ==="
echo ""

# Get IBM entitlement key from the standard location
IBM_ENTITLEMENT_AVAILABLE=false
IBM_ENTITLEMENT_KEY=""

echo "🔍 Checking for IBM entitlement credentials..."

# Check the standard credential location
if [[ -f "$IBM_ENTITLEMENT_KEY_PATH" ]]; then
  echo "✅ IBM entitlement credentials found at: $IBM_ENTITLEMENT_KEY_PATH"
  IBM_ENTITLEMENT_KEY="$(cat "$IBM_ENTITLEMENT_KEY_PATH")"
  IBM_ENTITLEMENT_AVAILABLE=true
else
  echo "❌ IBM entitlement credentials not found at: $IBM_ENTITLEMENT_KEY_PATH"
fi

# Get additional pull secret from the standard location
echo "🔍 Checking for additional pull secret credentials..."

FUSION_PULL_SECRET_EXTRA=""

# Check the standard credential location for additional pull secret
if [[ -f "$FUSION_PULL_SECRET_EXTRA_PATH" ]]; then
  echo "✅ Additional pull secret credentials found at: $FUSION_PULL_SECRET_EXTRA_PATH"
  FUSION_PULL_SECRET_EXTRA="$(cat "$FUSION_PULL_SECRET_EXTRA_PATH")"
  echo "✅ FUSION_PULL_SECRET_EXTRA environment variable set from mounted secret"
else
  echo "❌ Additional pull secret credentials not found at: $FUSION_PULL_SECRET_EXTRA_PATH"
fi

# Check if credentials are missing
if [[ "$IBM_ENTITLEMENT_AVAILABLE" == "false" ]]; then
  echo ""
  echo "⚠️  WARNING: IBM entitlement credentials not found at expected location"
  echo ""
  echo "Expected location: $IBM_ENTITLEMENT_KEY_PATH"
  echo ""
  echo "Proceeding without IBM entitlement secret creation..."
  echo "Some IBM images may not be accessible in this run"
fi

# Create fusion-pullsecret with IBM entitlement key
echo ""
echo "🔐 Creating fusion-pullsecret..."

# Check if fusion-pullsecret already exists
if oc get secret fusion-pullsecret -n "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "✅ fusion-pullsecret already exists in namespace"
  echo "✅ Using existing fusion-pullsecret"
  
  # Check if it's referenced in the service account
  CURRENT_SA_SECRETS=$(oc get serviceaccount default -n "${FUSION_ACCESS_NAMESPACE}" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || echo "")
  if [[ "$CURRENT_SA_SECRETS" == *"fusion-pullsecret"* ]]; then
    echo "✅ fusion-pullsecret already referenced in default service account"
  else
    echo "⚠️  fusion-pullsecret not referenced in default service account"
    echo "Adding fusion-pullsecret to default service account..."
    oc patch serviceaccount default -n "${FUSION_ACCESS_NAMESPACE}" -p '{"imagePullSecrets":[{"name":"fusion-pullsecret"}]}'
    echo "✅ fusion-pullsecret added to default service account"
  fi
elif [[ "$IBM_ENTITLEMENT_AVAILABLE" == "true" ]]; then
  echo "✅ IBM entitlement key provided, creating fusion-pullsecret"
  
  # Debug: Show credential info (without exposing the actual key)
  echo "🔍 Credential details:"
  echo "  - Key length: ${#IBM_ENTITLEMENT_KEY} characters"
  echo "  - Key format: ${IBM_ENTITLEMENT_KEY:0:10}... (first 10 chars)"
  echo "  - Target registry: ${IBM_REGISTRY}"
  
  # Create the secret in the correct format for IBM Container Registry
  oc apply -f=- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: fusion-pullsecret
  namespace: ${FUSION_ACCESS_NAMESPACE}
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {
      "auths": {
        "${IBM_REGISTRY}": {
          "auth": "$(echo -n "cp:${IBM_ENTITLEMENT_KEY}" | base64 -w 0)",
          "email": ""
        }
      }
    }
EOF
  
  echo "Waiting for fusion-pullsecret to be ready..."
  oc wait --for=jsonpath='{.metadata.name}'=fusion-pullsecret secret/fusion-pullsecret -n ${FUSION_ACCESS_NAMESPACE} --timeout=60s
  echo "✅ fusion-pullsecret created successfully"
  
  # Also create ibm-entitlement-key secret for IBM Storage Scale pods
  echo "🔐 Creating ibm-entitlement-key secret for IBM Storage Scale..."
  oc apply -f=- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ibm-entitlement-key
  namespace: ${FUSION_ACCESS_NAMESPACE}
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {
      "auths": {
        "${IBM_REGISTRY}": {
          "auth": "$(echo -n "cp:${IBM_ENTITLEMENT_KEY}" | base64 -w 0)",
          "email": ""
        }
      }
    }
EOF
  
  echo "Waiting for ibm-entitlement-key to be ready..."
  oc wait --for=jsonpath='{.metadata.name}'=ibm-entitlement-key secret/ibm-entitlement-key -n ${FUSION_ACCESS_NAMESPACE} --timeout=60s
  echo "✅ ibm-entitlement-key created successfully"
  
  # Add IBM entitlement key to global cluster pull secret
  # This makes it available cluster-wide to all namespaces automatically
  echo ""
  echo "🌐 Adding IBM entitlement key to global cluster pull secret..."
  
  # Get the current global pull secret
  CURRENT_PULL_SECRET=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
  
  # Create updated pull secret using Python (jq not available in base image)
  UPDATED_PULL_SECRET=$(python3 -c "
import json, sys, base64

# Read current pull secret
current = json.loads('''${CURRENT_PULL_SECRET}''')

# Add IBM registry
auth_string = 'cp:${IBM_ENTITLEMENT_KEY}'
encoded_auth = base64.b64encode(auth_string.encode()).decode()
current['auths']['${IBM_REGISTRY}'] = {'auth': encoded_auth, 'email': ''}

# Add extra registry if provided
extra_secret = '''${FUSION_PULL_SECRET_EXTRA:-}'''
if extra_secret:
    current['auths']['quay.io/openshift-storage-scale'] = {'auth': extra_secret, 'email': ''}

# Output updated secret
print(json.dumps(current))
")
  
  if [[ -n "${FUSION_PULL_SECRET_EXTRA:-}" ]]; then
    echo "✅ Added IBM and extra pull secrets to global pull secret"
  else
    echo "✅ Added IBM pull secret to global pull secret"
  fi
  
  # Update the global pull secret
  echo "${UPDATED_PULL_SECRET}" | oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/dev/stdin
  
  echo "✅ Global pull secret updated successfully"
  echo "   Registries now accessible from all namespaces:"
  echo "   - ${IBM_REGISTRY}"
  if [[ -n "${FUSION_PULL_SECRET_EXTRA:-}" ]]; then
    echo "   - quay.io/openshift-storage-scale"
  fi
  echo ""
  
  # Also create ibm-entitlement-key secret in key namespaces for explicit reference
  echo "📦 Creating ibm-entitlement-key secrets in IBM Storage Scale namespaces..."
  echo "   (These are for explicit imagePullSecrets references)"
  
  # Function to create ibm-entitlement-key secret in a namespace
  create_entitlement_secret_in_namespace() {
    local target_namespace=$1
    
    # Check if namespace exists first
    if ! oc get namespace "${target_namespace}" >/dev/null 2>&1; then
      echo "  ⚠️  ${target_namespace}: Namespace doesn't exist yet, skipping"
      return 0
    fi
    
    # Check if secret already exists
    if oc get secret ibm-entitlement-key -n "${target_namespace}" >/dev/null 2>&1; then
      echo "  ✅ ${target_namespace}: ibm-entitlement-key already exists"
      return 0
    fi
    
    # Create the secret
    if oc apply -f=- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ibm-entitlement-key
  namespace: ${target_namespace}
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {
      "auths": {
        "${IBM_REGISTRY}": {
          "auth": "$(echo -n "cp:${IBM_ENTITLEMENT_KEY}" | base64 -w 0)",
          "email": ""
        }
      }
    }
EOF
    then
      oc wait --for=jsonpath='{.metadata.name}'=ibm-entitlement-key secret/ibm-entitlement-key -n ${target_namespace} --timeout=60s >/dev/null 2>&1
      echo "  ✅ ${target_namespace}: ibm-entitlement-key created"
    else
      echo "  ❌ ${target_namespace}: Failed to create secret"
      return 1
    fi
  }
  
  # Create in specific namespaces that may explicitly reference the secret
  for ns in "${STORAGE_SCALE_NAMESPACE}" "${STORAGE_SCALE_DNS_NAMESPACE}" "${STORAGE_SCALE_CSI_NAMESPACE}" "${STORAGE_SCALE_OPERATOR_NAMESPACE}"; do
    create_entitlement_secret_in_namespace "$ns"
  done
  
  echo ""
  echo "✅ IBM entitlement key configured globally and in specific namespaces"
  
  # Verify the secret was created
  if oc get secret fusion-pullsecret -n "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
    echo "✅ fusion-pullsecret verified in namespace"
    
    # Check if the secret needs to be referenced in the service account
    echo "🔗 Checking if secret needs to be referenced in service account..."
    CURRENT_SA_SECRETS=$(oc get serviceaccount default -n "${FUSION_ACCESS_NAMESPACE}" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || echo "")
    if [[ "$CURRENT_SA_SECRETS" == *"fusion-pullsecret"* ]]; then
      echo "✅ fusion-pullsecret already referenced in default service account"
    else
      echo "⚠️  fusion-pullsecret not referenced in default service account"
      echo "Adding fusion-pullsecret to default service account..."
      oc patch serviceaccount default -n "${FUSION_ACCESS_NAMESPACE}" -p '{"imagePullSecrets":[{"name":"fusion-pullsecret"}]}'
      echo "✅ fusion-pullsecret added to default service account"
    fi
  else
    echo "❌ fusion-pullsecret not found after creation"
  fi
else
  echo "⚠️  WARNING: IBM entitlement credentials not available"
  echo "Skipping fusion-pullsecret creation - IBM Storage Scale images will not be accessible"
  echo "This indicates a credential mounting issue"
  echo ""
  echo "To resolve this in production runs:"
  echo "1. Ensure IBM entitlement credentials are mounted at: $IBM_ENTITLEMENT_KEY_PATH"
  echo "2. The credentials should provide access to ${IBM_REGISTRY} registry"
fi

# Create fusion-pullsecret-extra for additional registry access
echo ""
echo "🔐 Creating fusion-pullsecret-extra..."

# Check if fusion-pullsecret-extra already exists in the namespace
if oc get secret fusion-pullsecret-extra -n "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "✅ fusion-pullsecret-extra already exists in namespace"
  echo "✅ Using existing fusion-pullsecret-extra"
  
  # Check if it's referenced in the service account
  CURRENT_SA_SECRETS=$(oc get serviceaccount default -n "${FUSION_ACCESS_NAMESPACE}" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || echo "")
  if [[ "$CURRENT_SA_SECRETS" == *"fusion-pullsecret-extra"* ]]; then
    echo "✅ fusion-pullsecret-extra already referenced in default service account"
  else
    echo "⚠️  fusion-pullsecret-extra not referenced in default service account"
    echo "Adding fusion-pullsecret-extra to default service account..."
    # Get existing secrets and add the new one
    EXISTING_SECRETS=$(oc get serviceaccount default -n "${FUSION_ACCESS_NAMESPACE}" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || echo "")
    if [[ -n "$EXISTING_SECRETS" ]]; then
      oc patch serviceaccount default -n "${FUSION_ACCESS_NAMESPACE}" -p "{\"imagePullSecrets\":[{\"name\":\"fusion-pullsecret\"},{\"name\":\"fusion-pullsecret-extra\"}]}"
    else
      oc patch serviceaccount default -n "${FUSION_ACCESS_NAMESPACE}" -p '{"imagePullSecrets":[{"name":"fusion-pullsecret-extra"}]}'
    fi
    echo "✅ fusion-pullsecret-extra added to default service account"
  fi
else
  # Try to create fusion-pullsecret-extra if credentials are available
  if [[ -n "${FUSION_PULL_SECRET_EXTRA:-}" ]]; then
    echo "✅ Additional pull secret provided, creating fusion-pullsecret-extra"
    
    # Debug: Show credential info (without exposing the actual key)
    echo "🔍 Additional credential details:"
    echo "  - Key length: ${#FUSION_PULL_SECRET_EXTRA} characters"
    echo "  - Key format: ${FUSION_PULL_SECRET_EXTRA:0:10}... (first 10 chars)"
    echo "  - Target registry: quay.io/openshift-storage-scale"
    
    oc apply -f=- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: fusion-pullsecret-extra
  namespace: ${FUSION_ACCESS_NAMESPACE}
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {
      "auths": {
        "quay.io/openshift-storage-scale": {
          "auth": "${FUSION_PULL_SECRET_EXTRA}",
          "email": ""
        }
      }
    }
EOF
    
    echo "Waiting for fusion-pullsecret-extra to be ready..."
    oc wait --for=jsonpath='{.metadata.name}'=fusion-pullsecret-extra secret/fusion-pullsecret-extra -n ${FUSION_ACCESS_NAMESPACE} --timeout=60s
    echo "✅ fusion-pullsecret-extra created successfully"
    
    # Verify the secret was created
    if oc get secret fusion-pullsecret-extra -n "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
      echo "✅ fusion-pullsecret-extra verified in namespace"
      
      # Check if the secret needs to be referenced in the service account
      echo "🔗 Checking if fusion-pullsecret-extra needs to be referenced in service account..."
      CURRENT_SA_SECRETS=$(oc get serviceaccount default -n "${FUSION_ACCESS_NAMESPACE}" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || echo "")
      if [[ "$CURRENT_SA_SECRETS" == *"fusion-pullsecret-extra"* ]]; then
        echo "✅ fusion-pullsecret-extra already referenced in default service account"
      else
        echo "⚠️  fusion-pullsecret-extra not referenced in default service account"
        echo "Adding fusion-pullsecret-extra to default service account..."
        # Get existing secrets and add the new one
        EXISTING_SECRETS=$(oc get serviceaccount default -n "${FUSION_ACCESS_NAMESPACE}" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || echo "")
        if [[ -n "$EXISTING_SECRETS" ]]; then
          oc patch serviceaccount default -n "${FUSION_ACCESS_NAMESPACE}" -p "{\"imagePullSecrets\":[{\"name\":\"fusion-pullsecret\"},{\"name\":\"fusion-pullsecret-extra\"}]}"
        else
          oc patch serviceaccount default -n "${FUSION_ACCESS_NAMESPACE}" -p '{"imagePullSecrets":[{"name":"fusion-pullsecret-extra"}]}'
        fi
        echo "✅ fusion-pullsecret-extra added to default service account"
      fi
    else
      echo "❌ fusion-pullsecret-extra not found after creation"
    fi
  else
    echo "⚠️  WARNING: FUSION_PULL_SECRET_EXTRA not provided, skipping fusion-pullsecret-extra creation"
    echo "Some registry images may not be accessible"
  fi
fi

echo ""
echo "📋 Pull secrets creation summary:"
# Check if fusion-pullsecret exists (either created or already present)
if oc get secret fusion-pullsecret -n "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "✅ fusion-pullsecret: Available (existing or created)"
  echo "✅ Service account: Updated with pull secret"
elif [[ "$IBM_ENTITLEMENT_AVAILABLE" == "true" ]]; then
  echo "✅ IBM entitlement credentials: Available"
  echo "✅ fusion-pullsecret: Created (supports ${IBM_REGISTRY})"
  echo "✅ Global cluster pull secret: Updated with IBM credentials (available to ALL namespaces)"
  echo "✅ ibm-entitlement-key: Created in ${FUSION_ACCESS_NAMESPACE} namespace"
  echo "✅ ibm-entitlement-key: Created in IBM Storage Scale namespaces (for explicit reference)"
  if [[ -n "${FUSION_PULL_SECRET_EXTRA:-}" ]]; then
    echo "✅ Extra pull secret: Added to global pull secret (quay.io/openshift-storage-scale)"
  fi
  echo "✅ Service account: Updated with pull secret"
else
  echo "⚠️  IBM entitlement credentials: Not available"
  echo "⚠️  fusion-pullsecret: Not created (will use existing if available)"
  echo "⚠️  ibm-entitlement-key: Not created (will use existing if available)"
fi

# Check if fusion-pullsecret-extra exists (either created or already present)
if oc get secret fusion-pullsecret-extra -n "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "✅ fusion-pullsecret-extra: Available (existing or created)"
  echo "✅ Service account: Updated with additional pull secret"
else
  echo "⚠️  fusion-pullsecret-extra: Not available"
  echo "⚠️  Additional pull secret: Not provided or creation failed"
fi

echo ""
echo "✅ All Fusion Access pull secrets creation completed!"
