#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"

echo "🚀 Creating Fusion Access pull secrets..."

# Check if namespace exists
if ! oc get namespace "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "❌ ERROR: Namespace ${FUSION_ACCESS_NAMESPACE} does not exist"
  echo "Please ensure the namespace creation step runs before this step"
  exit 1
fi

echo "✅ Namespace ${FUSION_ACCESS_NAMESPACE} exists"

# Get IBM entitlement key from the standard location
IBM_ENTITLEMENT_KEY=""
IBM_ENTITLEMENT_AVAILABLE=false

echo "🔍 Checking for IBM entitlement credentials..."

# Check the standard mounted secret path
if [[ -f "/var/run/secrets/ibm-entitlement-key" ]]; then
  echo "✅ IBM entitlement credentials found at: /var/run/secrets/ibm-entitlement-key"
  IBM_ENTITLEMENT_KEY="$(cat /var/run/secrets/ibm-entitlement-key)"
  IBM_ENTITLEMENT_AVAILABLE=true
else
  echo "❌ IBM entitlement credentials not found at: /var/run/secrets/ibm-entitlement-key"
fi

# Get additional pull secret from the standard location
echo "🔍 Checking for additional pull secret credentials..."

# Check the standard mounted secret path
if [[ -f "/var/run/secrets/fusion-pullsecret-extra" ]]; then
  echo "✅ Additional pull secret credentials found at: /var/run/secrets/fusion-pullsecret-extra"
  FUSION_PULL_SECRET_EXTRA="$(cat /var/run/secrets/fusion-pullsecret-extra)"
  echo "✅ FUSION_PULL_SECRET_EXTRA environment variable set from mounted secret"
else
  echo "❌ Additional pull secret credentials not found at: /var/run/secrets/fusion-pullsecret-extra"
fi

# Check if credentials are missing (unexpected in rehearsal runs)
if [[ "$IBM_ENTITLEMENT_AVAILABLE" == "false" ]]; then
  echo ""
  echo "❌ ERROR: IBM entitlement credentials not found at expected location"
  echo "IBM Storage Scale images require IBM entitlement to pull from icr.io"
  echo ""
  echo "Expected location: /var/run/secrets/ibm-entitlement-key"
  echo ""
  echo "This is unexpected - rehearsal runs should have IBM credentials available"
  echo "Please check the credential mounting configuration"
  exit 1
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
  echo "  - Target registry: icr.io"
  
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
        "icr.io": {
          "auth": "$(echo -n "cp:${IBM_ENTITLEMENT_KEY}" | base64 -w 0)",
          "email": ""
        }
      }
    }
EOF
  
  echo "Waiting for fusion-pullsecret to be ready..."
  oc wait --for=jsonpath='{.metadata.name}'=fusion-pullsecret secret/fusion-pullsecret -n ${FUSION_ACCESS_NAMESPACE} --timeout=60s
  echo "✅ fusion-pullsecret created successfully"
  
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
  echo "1. Ensure IBM entitlement credentials are mounted at one of the expected paths"
  echo "2. Or set the IBM_ENTITLEMENT_KEY environment variable"
  echo "3. The credentials should provide access to icr.io registry"
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
  echo "✅ fusion-pullsecret: Created"
  echo "✅ Service account: Updated with pull secret"
else
  echo "❌ IBM entitlement credentials: Not available (unexpected)"
  echo "❌ fusion-pullsecret: Not created"
  echo "❌ This indicates a credential mounting issue"
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
