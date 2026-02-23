#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__NAMESPACE="${FA__NAMESPACE:-ibm-fusion-access}"
FA__IBM_REGISTRY="${FA__IBM_REGISTRY:-cp.icr.io}"
FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"
FA__SCALE__DNS_NAMESPACE="${FA__SCALE__DNS_NAMESPACE:-ibm-spectrum-scale-dns}"
FA__SCALE__CSI_NAMESPACE="${FA__SCALE__CSI_NAMESPACE:-ibm-spectrum-scale-csi}"
FA__SCALE__OPERATOR_NAMESPACE="${FA__SCALE__OPERATOR_NAMESPACE:-ibm-spectrum-scale-operator}"

# Credential paths
ibmEntitlementKeyPath="/var/run/secrets/ibm-entitlement-key"
fusionPullSecretExtraPath="/var/run/secrets/fusion-pullsecret-extra"

: 'Creating Fusion Access pull secrets...'

# Check if namespace exists
if ! oc get namespace "${FA__NAMESPACE}" >/dev/null; then
  : "ERROR: Namespace ${FA__NAMESPACE} does not exist"
  : 'Please ensure the namespace creation step runs before this step'
  exit 1
fi

: "Namespace ${FA__NAMESPACE} exists"

# Debug: Show what credential files are actually mounted
: '=== DEBUGGING CREDENTIAL MOUNTS ==='
: 'Checking credential mount at: /var/run/secrets/'

if [ -d "/var/run/secrets" ]; then
  : 'Mount directory exists: /var/run/secrets/'
  if ! ls -la /var/run/secrets/; then
    : 'Cannot list directory contents'
  fi
  : 'Checking for specific credential files:'
  for file in "ibm-entitlement-key" "fusion-pullsecret-extra"; do
    if [ -f "/var/run/secrets/$file" ] || [ -L "/var/run/secrets/$file" ]; then
      if size=$(stat -c%s "/var/run/secrets/$file"); then
        : "${file} (${size} bytes)"
      else
        : "${file} (size unknown)"
      fi
    else
      : "${file} (not found)"
    fi
  done
else
  : 'Mount directory DOES NOT EXIST: /var/run/secrets/'
fi

: '=== END DEBUGGING ==='

# Get IBM entitlement key from the standard location
ibmEntitlementAvailable=false
ibmEntitlementKey=""

: 'Checking for IBM entitlement credentials...'

# Check the standard credential location
set +x  # Disable tracing - reading credential file
if [[ -f "$ibmEntitlementKeyPath" ]]; then
  : "IBM entitlement credentials found at: $ibmEntitlementKeyPath"
  ibmEntitlementKey="$(cat "$ibmEntitlementKeyPath")"
  ibmEntitlementAvailable=true
else
  : "IBM entitlement credentials not found at: $ibmEntitlementKeyPath"
fi
set -x

# Get additional pull secret from the standard location
: 'Checking for additional pull secret credentials...'

FA__PULL_SECRET_EXTRA=""

# Check the standard credential location for additional pull secret
set +x  # Disable tracing - reading credential file
if [[ -f "$fusionPullSecretExtraPath" ]]; then
  : "Additional pull secret credentials found at: $fusionPullSecretExtraPath"
  FA__PULL_SECRET_EXTRA="$(cat "$fusionPullSecretExtraPath")"
  : 'FA__PULL_SECRET_EXTRA environment variable set from mounted secret'
else
  : "Additional pull secret credentials not found at: $fusionPullSecretExtraPath"
fi
set -x

# Fail fast if credentials are missing
if [[ "$ibmEntitlementAvailable" == "false" ]]; then
  : '❌ IBM entitlement credentials not found at expected location'
  : "Expected location: $ibmEntitlementKeyPath"
  exit 1
fi

# Create fusion-pullsecret with IBM entitlement key
: 'Creating fusion-pullsecret...'

# Check if fusion-pullsecret already exists
if oc get secret fusion-pullsecret -n "${FA__NAMESPACE}" >/dev/null; then
  : 'fusion-pullsecret already exists in namespace'
  : 'Using existing fusion-pullsecret'
  
  if ! currentSaSecrets=$(oc get serviceaccount default -n "${FA__NAMESPACE}" -o jsonpath='{.imagePullSecrets[*].name}'); then
    currentSaSecrets=""
  fi
  if [[ "$currentSaSecrets" == *"fusion-pullsecret"* ]]; then
    : 'fusion-pullsecret already referenced in default service account'
  else
    : 'Adding fusion-pullsecret to default service account...'
    oc patch serviceaccount default -n "${FA__NAMESPACE}" -p '{"imagePullSecrets":[{"name":"fusion-pullsecret"}]}'
  fi
elif [[ "$ibmEntitlementAvailable" == "true" ]]; then
  : 'IBM entitlement key provided, creating fusion-pullsecret'
  
  # Debug: Show credential info (without exposing the actual key)
  : "  Target registry: ${FA__IBM_REGISTRY}"
  
  # Create the secret in the format expected by FusionAccess operator
  # The operator's getPullSecretContent() expects type: Opaque with key: ibm-entitlement-key
  set +x  # Disable tracing - credential in heredoc
  oc apply -f=- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: fusion-pullsecret
  namespace: ${FA__NAMESPACE}
type: Opaque
stringData:
  ibm-entitlement-key: "${ibmEntitlementKey}"
EOF
  set -x
  
  : 'Waiting for fusion-pullsecret to be ready...'
  oc wait --for=jsonpath='{.metadata.name}'=fusion-pullsecret secret/fusion-pullsecret -n "${FA__NAMESPACE}" --timeout=60s
  : 'fusion-pullsecret created successfully'
  
  # Also create ibm-entitlement-key secret for IBM Storage Scale pods
  : 'Creating ibm-entitlement-key secret for IBM Storage Scale...'
  set +x  # Disable tracing - credential in heredoc
  oc apply -f=- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ibm-entitlement-key
  namespace: ${FA__NAMESPACE}
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {
      "auths": {
        "${FA__IBM_REGISTRY}": {
          "auth": "$(echo -n "cp:${ibmEntitlementKey}" | base64 -w 0)",
          "email": ""
        }
      }
    }
EOF
  set -x
  
  : 'Waiting for ibm-entitlement-key to be ready...'
  oc wait --for=jsonpath='{.metadata.name}'=ibm-entitlement-key secret/ibm-entitlement-key -n "${FA__NAMESPACE}" --timeout=60s
  : 'ibm-entitlement-key created successfully'
  
  # Add IBM entitlement key to global cluster pull secret
  # This makes it available cluster-wide to all namespaces automatically
  : 'Adding IBM entitlement key to global cluster pull secret...'
  
  # Get the current global pull secret
  set +x  # Disable tracing - credential processing
  currentPullSecret=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
  
  # Create updated pull secret using Python (jq not available in base image)
  updatedPullSecret=$(python3 -c "
import json, sys, base64

# Read current pull secret
current = json.loads('''${currentPullSecret}''')

# Add IBM registry
auth_string = 'cp:${ibmEntitlementKey}'
encoded_auth = base64.b64encode(auth_string.encode()).decode()
current['auths']['${FA__IBM_REGISTRY}'] = {'auth': encoded_auth, 'email': ''}

# Add extra registry if provided
extra_secret = '''${FA__PULL_SECRET_EXTRA:-}'''
if extra_secret:
    current['auths']['quay.io/openshift-storage-scale'] = {'auth': extra_secret, 'email': ''}

# Output updated secret
print(json.dumps(current))
")
  
  if [[ -n "${FA__PULL_SECRET_EXTRA:-}" ]]; then
    : 'Added IBM and extra pull secrets to global pull secret'
  else
    : 'Added IBM pull secret to global pull secret'
  fi
  
  # Update the global pull secret
  echo "${updatedPullSecret}" | oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/dev/stdin
  set -x
  
  : 'Global pull secret updated successfully'
  
  # Also create ibm-entitlement-key secret in key namespaces for explicit reference
  : 'Creating ibm-entitlement-key secrets in IBM Storage Scale namespaces...'
  
  # Function to create ibm-entitlement-key secret in a namespace
  CreateEntitlementSecretInNamespace() {
    typeset targetNamespace="${1}"; (($#)) && shift
    
    # Check if namespace exists first
    if ! oc get namespace "${targetNamespace}" >/dev/null; then
      : "${targetNamespace}: Namespace does not exist yet, skipping"
      return 0
    fi
    
    # Check if secret already exists
    if oc get secret ibm-entitlement-key -n "${targetNamespace}" >/dev/null; then
      : "${targetNamespace}: ibm-entitlement-key already exists"
      return 0
    fi
    
    # Create the secret
    set +x  # Disable tracing - credential in heredoc
    if oc apply -f=- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ibm-entitlement-key
  namespace: ${targetNamespace}
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {
      "auths": {
        "${FA__IBM_REGISTRY}": {
          "auth": "$(echo -n "cp:${ibmEntitlementKey}" | base64 -w 0)",
          "email": ""
        }
      }
    }
EOF
    then
      set -x
      oc wait --for=jsonpath='{.metadata.name}'=ibm-entitlement-key secret/ibm-entitlement-key -n "${targetNamespace}" --timeout=60s >/dev/null
      : "${targetNamespace}: ibm-entitlement-key created"
    else
      set -x
      : "${targetNamespace}: Failed to create secret"
      return 1
    fi

    true
  }
  
  # Create in specific namespaces that may explicitly reference the secret
  for ns in "${FA__SCALE__NAMESPACE}" "${FA__SCALE__DNS_NAMESPACE}" "${FA__SCALE__CSI_NAMESPACE}" "${FA__SCALE__OPERATOR_NAMESPACE}"; do
    CreateEntitlementSecretInNamespace "$ns"
  done
  
  : 'IBM entitlement key configured globally and in specific namespaces'
  
  # Verify the secret was created
  if oc get secret fusion-pullsecret -n "${FA__NAMESPACE}" >/dev/null; then
    : 'fusion-pullsecret verified in namespace'
    
    : 'Checking if secret needs to be referenced in service account...'
    if ! currentSaSecrets=$(oc get serviceaccount default -n "${FA__NAMESPACE}" -o jsonpath='{.imagePullSecrets[*].name}'); then
      currentSaSecrets=""
    fi
    if [[ "$currentSaSecrets" != *"fusion-pullsecret"* ]]; then
      : 'Adding fusion-pullsecret to default service account...'
      oc patch serviceaccount default -n "${FA__NAMESPACE}" -p '{"imagePullSecrets":[{"name":"fusion-pullsecret"}]}'
    fi
  else
    : '❌ fusion-pullsecret not found after creation'
    exit 1
  fi
fi

# Create fusion-pullsecret-extra for additional registry access
: 'Creating fusion-pullsecret-extra...'

# Check if fusion-pullsecret-extra already exists in the namespace
if oc get secret fusion-pullsecret-extra -n "${FA__NAMESPACE}" >/dev/null; then
  : 'fusion-pullsecret-extra already exists in namespace'
  : 'Using existing fusion-pullsecret-extra'
  
  if ! currentSaSecrets=$(oc get serviceaccount default -n "${FA__NAMESPACE}" -o jsonpath='{.imagePullSecrets[*].name}'); then
    currentSaSecrets=""
  fi
  if [[ "$currentSaSecrets" != *"fusion-pullsecret-extra"* ]]; then
    : 'Adding fusion-pullsecret-extra to default service account...'
    if ! existingSecrets=$(oc get serviceaccount default -n "${FA__NAMESPACE}" -o jsonpath='{.imagePullSecrets[*].name}'); then
      existingSecrets=""
    fi
    if [[ -n "$existingSecrets" ]]; then
      oc patch serviceaccount default -n "${FA__NAMESPACE}" -p "{\"imagePullSecrets\":[{\"name\":\"fusion-pullsecret\"},{\"name\":\"fusion-pullsecret-extra\"}]}"
    else
      oc patch serviceaccount default -n "${FA__NAMESPACE}" -p '{"imagePullSecrets":[{"name":"fusion-pullsecret-extra"}]}'
    fi
  fi
else
  # Try to create fusion-pullsecret-extra if credentials are available
  if [[ -n "${FA__PULL_SECRET_EXTRA:-}" ]]; then
    : 'Additional pull secret provided, creating fusion-pullsecret-extra'
    
    # Debug: Show credential info (without exposing the actual key)
    set +x  # Disable tracing - credential in heredoc
    oc apply -f=- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: fusion-pullsecret-extra
  namespace: ${FA__NAMESPACE}
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {
      "auths": {
        "quay.io/openshift-storage-scale": {
          "auth": "${FA__PULL_SECRET_EXTRA}",
          "email": ""
        }
      }
    }
EOF
    set -x
    
    : 'Waiting for fusion-pullsecret-extra to be ready...'
    oc wait --for=jsonpath='{.metadata.name}'=fusion-pullsecret-extra secret/fusion-pullsecret-extra -n "${FA__NAMESPACE}" --timeout=60s
    : 'fusion-pullsecret-extra created successfully'
    
    # Verify the secret was created
    if oc get secret fusion-pullsecret-extra -n "${FA__NAMESPACE}" >/dev/null; then
      : 'fusion-pullsecret-extra verified in namespace'
      
      : 'Checking if fusion-pullsecret-extra needs to be referenced in service account...'
      if ! currentSaSecrets=$(oc get serviceaccount default -n "${FA__NAMESPACE}" -o jsonpath='{.imagePullSecrets[*].name}'); then
        currentSaSecrets=""
      fi
      if [[ "$currentSaSecrets" != *"fusion-pullsecret-extra"* ]]; then
        : 'Adding fusion-pullsecret-extra to default service account...'
        if ! existingSecrets=$(oc get serviceaccount default -n "${FA__NAMESPACE}" -o jsonpath='{.imagePullSecrets[*].name}'); then
          existingSecrets=""
        fi
        if [[ -n "$existingSecrets" ]]; then
          oc patch serviceaccount default -n "${FA__NAMESPACE}" -p "{\"imagePullSecrets\":[{\"name\":\"fusion-pullsecret\"},{\"name\":\"fusion-pullsecret-extra\"}]}"
        else
          oc patch serviceaccount default -n "${FA__NAMESPACE}" -p '{"imagePullSecrets":[{"name":"fusion-pullsecret-extra"}]}'
        fi
      fi
    else
      : '❌ fusion-pullsecret-extra not found after creation'
      exit 1
    fi
  else
    : 'WARNING: FA__PULL_SECRET_EXTRA not provided, skipping fusion-pullsecret-extra creation'
    : 'Some registry images may not be accessible'
  fi
fi

: 'Pull secrets creation summary'
if oc get secret fusion-pullsecret -n "${FA__NAMESPACE}" >/dev/null; then
  : 'fusion-pullsecret: Available'
fi

if oc get secret fusion-pullsecret-extra -n "${FA__NAMESPACE}" >/dev/null; then
  : 'fusion-pullsecret-extra: Available'
fi

: 'All Fusion Access pull secrets creation completed'

true
