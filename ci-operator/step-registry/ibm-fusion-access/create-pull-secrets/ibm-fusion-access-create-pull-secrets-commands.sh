#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

fusionAccessNamespace="${FA__NAMESPACE:-ibm-fusion-access}"
FA__IBM_REGISTRY="${FA__IBM_REGISTRY:-cp.icr.io}"
FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"
FA__SCALE__DNS_NAMESPACE="${FA__SCALE__DNS_NAMESPACE:-ibm-spectrum-scale-dns}"
FA__SCALE__CSI_NAMESPACE="${FA__SCALE__CSI_NAMESPACE:-ibm-spectrum-scale-csi}"
FA__SCALE__OPERATOR_NAMESPACE="${FA__SCALE__OPERATOR_NAMESPACE:-ibm-spectrum-scale-operator}"

# Credential paths
ibmEntitlementKeyPath="/var/run/secrets/ibm-entitlement-key"
FA__PULL_SECRET_EXTRA_PATH="/var/run/secrets/fusion-pullsecret-extra"

: 'Creating IBM Fusion Access pull secrets'

# Check if namespace exists
if ! oc get namespace "${fusionAccessNamespace}" >/dev/null; then
  : '❌ Namespace does not exist'
  exit 1
fi

# Debug: Show what credential files are actually mounted
if [ -d "/var/run/secrets" ]; then
  if ! ls -la /var/run/secrets/ | head -20; then
    : 'Cannot list directory contents'
  fi
  for file in "ibm-entitlement-key" "fusion-pullsecret-extra"; do
    if [ -f "/var/run/secrets/$file" ] || [ -L "/var/run/secrets/$file" ]; then
      stat -c%s "/var/run/secrets/${file}" || true
    fi
  done
fi

# Get IBM entitlement key from the standard location
ibmEntitlementAvailable=false
ibmEntitlementKey=""

# Check the standard credential location
if [[ -f "$ibmEntitlementKeyPath" ]]; then
  set +x
  ibmEntitlementKey="$(cat "$ibmEntitlementKeyPath")"
  set -x
  ibmEntitlementAvailable=true
fi

# Get additional pull secret from the standard location
FA__PULL_SECRET_EXTRA=""

# Check the standard credential location for additional pull secret
if [[ -f "$FA__PULL_SECRET_EXTRA_PATH" ]]; then
  set +x
  FA__PULL_SECRET_EXTRA="$(cat "$FA__PULL_SECRET_EXTRA_PATH")"
  set -x
fi

# Check if credentials are missing
if [[ "$ibmEntitlementAvailable" == "false" ]]; then
  : '❌ IBM entitlement credentials not found - failing fast'
  exit 1
fi

# Create fusion-pullsecret with IBM entitlement key

# Check if fusion-pullsecret already exists
if oc get secret fusion-pullsecret -n "${fusionAccessNamespace}" >/dev/null; then
  : '✅ fusion-pullsecret already exists in namespace'
  
  if ! currentSaSecrets=$(oc get serviceaccount default -n "${fusionAccessNamespace}" -o jsonpath='{.imagePullSecrets[*].name}'); then
    currentSaSecrets=""
  fi
  if [[ "$currentSaSecrets" != *"fusion-pullsecret"* ]]; then
    oc patch serviceaccount default -n "${fusionAccessNamespace}" -p '{"imagePullSecrets":[{"name":"fusion-pullsecret"}]}'
  fi
elif [[ "$ibmEntitlementAvailable" == "true" ]]; then
  # Create the secret in the correct format for IBM Container Registry
  set +x
  oc apply -f=- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: fusion-pullsecret
  namespace: ${fusionAccessNamespace}
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
  
  oc wait --for=jsonpath='{.metadata.name}'=fusion-pullsecret secret/fusion-pullsecret -n ${fusionAccessNamespace} --timeout=60s
  
  # Also create ibm-entitlement-key secret for IBM Storage Scale pods
  set +x
  oc apply -f=- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ibm-entitlement-key
  namespace: ${fusionAccessNamespace}
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
  
  oc wait --for=jsonpath='{.metadata.name}'=ibm-entitlement-key secret/ibm-entitlement-key -n ${fusionAccessNamespace} --timeout=60s
  
  # Add IBM entitlement key to global cluster pull secret
  # This makes it available cluster-wide to all namespaces automatically
  set +x
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
  
  # Update the global pull secret
  echo "${updatedPullSecret}" | oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/dev/stdin
  set -x
  
  # Function to create ibm-entitlement-key secret in a namespace
  CreateEntitlementSecretInNamespace() {
    typeset targetNamespace="${1}"; (($#)) && shift
    
    # Check if namespace exists first
    if ! oc get namespace "${targetNamespace}" >/dev/null; then
      return 0
    fi
    
    # Check if secret already exists
    if oc get secret ibm-entitlement-key -n "${targetNamespace}" >/dev/null; then
      return 0
    fi
    
    # Create the secret
    set +x
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
      oc wait --for=jsonpath='{.metadata.name}'=ibm-entitlement-key secret/ibm-entitlement-key -n ${targetNamespace} --timeout=60s >/dev/null
    else
      set -x
      return 1
    fi

    true
  }
  
  # Create in specific namespaces that may explicitly reference the secret
  for ns in "${FA__SCALE__NAMESPACE}" "${FA__SCALE__DNS_NAMESPACE}" "${FA__SCALE__CSI_NAMESPACE}" "${FA__SCALE__OPERATOR_NAMESPACE}"; do
    CreateEntitlementSecretInNamespace "$ns"
  done
  
  # Verify the secret was created
  if oc get secret fusion-pullsecret -n "${fusionAccessNamespace}" >/dev/null; then
    if ! currentSaSecrets=$(oc get serviceaccount default -n "${fusionAccessNamespace}" -o jsonpath='{.imagePullSecrets[*].name}'); then
      currentSaSecrets=""
    fi
    if [[ "$currentSaSecrets" != *"fusion-pullsecret"* ]]; then
      oc patch serviceaccount default -n "${fusionAccessNamespace}" -p '{"imagePullSecrets":[{"name":"fusion-pullsecret"}]}'
    fi
  else
    : '❌ fusion-pullsecret not found after creation'
    exit 1
  fi
fi

# Create fusion-pullsecret-extra for additional registry access

# Check if fusion-pullsecret-extra already exists in the namespace
if oc get secret fusion-pullsecret-extra -n "${fusionAccessNamespace}" >/dev/null; then
  : '✅ fusion-pullsecret-extra already exists in namespace'
  
  if ! currentSaSecrets=$(oc get serviceaccount default -n "${fusionAccessNamespace}" -o jsonpath='{.imagePullSecrets[*].name}'); then
    currentSaSecrets=""
  fi
  if [[ "$currentSaSecrets" != *"fusion-pullsecret-extra"* ]]; then
    if ! existingSecrets=$(oc get serviceaccount default -n "${fusionAccessNamespace}" -o jsonpath='{.imagePullSecrets[*].name}'); then
      existingSecrets=""
    fi
    if [[ -n "$existingSecrets" ]]; then
      oc patch serviceaccount default -n "${fusionAccessNamespace}" -p "{\"imagePullSecrets\":[{\"name\":\"fusion-pullsecret\"},{\"name\":\"fusion-pullsecret-extra\"}]}"
    else
      oc patch serviceaccount default -n "${fusionAccessNamespace}" -p '{"imagePullSecrets":[{"name":"fusion-pullsecret-extra"}]}'
    fi
  fi
else
  # Try to create fusion-pullsecret-extra if credentials are available
  if [[ -n "${FA__PULL_SECRET_EXTRA:-}" ]]; then
    set +x
    oc apply -f=- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: fusion-pullsecret-extra
  namespace: ${fusionAccessNamespace}
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
    
    oc wait --for=jsonpath='{.metadata.name}'=fusion-pullsecret-extra secret/fusion-pullsecret-extra -n ${fusionAccessNamespace} --timeout=60s
    
    # Verify the secret was created
    if oc get secret fusion-pullsecret-extra -n "${fusionAccessNamespace}" >/dev/null; then
      if ! currentSaSecrets=$(oc get serviceaccount default -n "${fusionAccessNamespace}" -o jsonpath='{.imagePullSecrets[*].name}'); then
        currentSaSecrets=""
      fi
      if [[ "$currentSaSecrets" != *"fusion-pullsecret-extra"* ]]; then
        if ! existingSecrets=$(oc get serviceaccount default -n "${fusionAccessNamespace}" -o jsonpath='{.imagePullSecrets[*].name}'); then
          existingSecrets=""
        fi
        if [[ -n "$existingSecrets" ]]; then
          oc patch serviceaccount default -n "${fusionAccessNamespace}" -p "{\"imagePullSecrets\":[{\"name\":\"fusion-pullsecret\"},{\"name\":\"fusion-pullsecret-extra\"}]}"
        else
          oc patch serviceaccount default -n "${fusionAccessNamespace}" -p '{"imagePullSecrets":[{"name":"fusion-pullsecret-extra"}]}'
        fi
      fi
    else
      : '❌ fusion-pullsecret-extra not found after creation'
      exit 1
    fi
  else
    : '⚠️  FA__PULL_SECRET_EXTRA not provided, skipping fusion-pullsecret-extra creation'
  fi
fi

# Summary verification
if oc get secret fusion-pullsecret -n "${fusionAccessNamespace}" >/dev/null; then
  : '✅ fusion-pullsecret: Available'
fi

if oc get secret fusion-pullsecret-extra -n "${fusionAccessNamespace}" >/dev/null; then
  : '✅ fusion-pullsecret-extra: Available'
fi

: '✅ All IBM Fusion Access pull secrets creation completed'

true
