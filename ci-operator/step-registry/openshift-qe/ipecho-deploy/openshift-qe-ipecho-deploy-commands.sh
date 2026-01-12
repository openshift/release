#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deploy ipecho service for egress IP functional validation

echo "Deploying ipecho service for functional egress IP validation"
echo "=========================================================="

# Configuration
IPECHO_NAMESPACE="${IPECHO_NAMESPACE:-ipecho-validation}"
IPECHO_IMAGE="${IPECHO_IMAGE:-quay.io/openshifttest/ip-echo:1.2.0}"

# Colors for output  
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }

error_exit() {
    log_error "$*"
    exit 1
}

# Validate cluster connectivity
if ! oc cluster-info &> /dev/null; then
    error_exit "Cannot connect to OpenShift cluster. Please check your kubeconfig."
fi

log_info "Creating namespace for ipecho service..."

# Create namespace for ipecho service
oc create namespace "$IPECHO_NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# Validate image availability (optional check to catch pull issues early)
log_info "Validating ipecho image availability..."
if ! oc run ipecho-image-test --image="$IPECHO_IMAGE" --dry-run=server -o yaml -n "$IPECHO_NAMESPACE" &>/dev/null; then
    log_warning "Image validation check failed, but proceeding with deployment..."
fi

log_info "Deploying ipecho service components..."

# Deploy ipecho service
cat << EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ipecho
  namespace: $IPECHO_NAMESPACE
  labels:
    app: ipecho
    component: egress-ip-validation
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ipecho
  template:
    metadata:
      labels:
        app: ipecho
        component: egress-ip-validation
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: ipecho
        image: $IPECHO_IMAGE
        imagePullPolicy: Always
        ports:
        - name: http
          containerPort: 8080
          protocol: TCP
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          capabilities:
            drop:
            - ALL
          seccompProfile:
            type: RuntimeDefault
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
        readinessProbe:
          httpGet:
            path: /
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 15
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: ipecho
  namespace: $IPECHO_NAMESPACE
  labels:
    app: ipecho
    component: egress-ip-validation
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
  selector:
    app: ipecho
EOF

# Wait for deployment to be ready with extended timeout
log_info "Waiting for ipecho deployment to be ready..."
if ! oc rollout status deployment/ipecho -n "$IPECHO_NAMESPACE" --timeout=300s; then
    log_error "ipecho deployment failed to become ready within 300 seconds"
    log_info "Gathering debug information..."
    
    # Show pod status and events for debugging
    log_info "Pod status:"
    oc get pods -n "$IPECHO_NAMESPACE" -l app=ipecho -o wide || true
    
    log_info "Pod events:"
    oc get events -n "$IPECHO_NAMESPACE" --sort-by='.lastTimestamp' || true
    
    log_info "Pod logs:"
    oc logs -n "$IPECHO_NAMESPACE" -l app=ipecho --tail=50 || true
    
    log_info "Deployment status:"
    oc describe deployment ipecho -n "$IPECHO_NAMESPACE" || true
    
    error_exit "ipecho deployment failed to become ready"
fi

# Validate service is working
log_info "Validating ipecho service functionality..."

# Create temporary test pod to validate ipecho
cat << EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ipecho-test-pod
  namespace: $IPECHO_NAMESPACE
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: curl-container
    image: quay.io/openshift/origin-network-tools:latest
    command: ["/bin/sleep", "120"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      capabilities:
        drop:
        - ALL
      seccompProfile:
        type: RuntimeDefault
  restartPolicy: Never
EOF

# Wait for test pod and validate ipecho service
log_info "Waiting for test pod to become ready..."
if oc wait --for=condition=Ready pod/ipecho-test-pod -n "$IPECHO_NAMESPACE" --timeout=120s; then
    log_info "Testing ipecho service functionality..."
    
    # Test ipecho service response
    if ipecho_response=$(oc exec -n "$IPECHO_NAMESPACE" ipecho-test-pod -- timeout 10 curl -s "http://ipecho.${IPECHO_NAMESPACE}.svc.cluster.local"); then
        log_success "ipecho service is working correctly!"
        log_info "Sample response: $ipecho_response"
    else
        log_error "ipecho service test failed"
        oc logs -n "$IPECHO_NAMESPACE" deployment/ipecho --tail=20 || true
        error_exit "ipecho service validation failed"
    fi
    
    # Cleanup test pod
    oc delete pod ipecho-test-pod -n "$IPECHO_NAMESPACE" --ignore-not-found=true
else
    log_error "Test pod failed to become ready"
    error_exit "ipecho service validation failed"
fi

log_success "ipecho service deployed and validated successfully!"
log_info "Service endpoint: http://ipecho.${IPECHO_NAMESPACE}.svc.cluster.local"
log_info "Namespace: $IPECHO_NAMESPACE"
log_info "Ready for functional egress IP validation"

echo "=========================================================="
echo "✅ ipecho service deployment completed successfully"