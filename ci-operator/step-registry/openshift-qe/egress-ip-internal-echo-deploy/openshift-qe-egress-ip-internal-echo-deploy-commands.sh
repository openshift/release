#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deploy Internal IP Echo Service for Egress IP Source Validation
# This service runs inside the cluster and can see actual source IPs before NAT translation

echo "Deploying Internal IP Echo Service for Egress IP Validation"
echo "============================================================"

# Configuration variables used in script
# Note: These are used directly in the YAML manifests below

# Logging functions  
log_info() { echo -e "\033[0;34m[INFO]\033[0m [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
log_success() { echo -e "\033[0;32m[SUCCESS]\033[0m [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }

error_exit() {
    log_error "$*"
    exit 1
}

# Check cluster connectivity
if ! oc cluster-info &> /dev/null; then
    error_exit "Cannot connect to OpenShift cluster. Please check your kubeconfig."
fi

log_info "Creating namespace for internal IP echo service..."
cat << 'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: egress-ip-validation
  labels:
    name: egress-ip-validation
    purpose: internal-source-ip-validation
EOF

log_info "Deploying internal IP echo service that reports source IPs..."
cat << 'EOF' | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: internal-ipecho
  namespace: egress-ip-validation
spec:
  replicas: 2
  selector:
    matchLabels:
      app: internal-ipecho
  template:
    metadata:
      labels:
        app: internal-ipecho
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: ipecho-server
        image: quay.io/openshift/origin-network-tools:latest
        command: ["/bin/bash", "-c"]
        args:
        - |
          cat > /tmp/ipecho-server.py << 'PYEOF'
          #!/usr/bin/env python3
          import socket
          import json
          from http.server import HTTPServer, BaseHTTPRequestHandler
          from urllib.parse import urlparse, parse_qs
          import datetime
          
          class IPEchoHandler(BaseHTTPRequestHandler):
              def do_GET(self):
                  # Get client IP (source IP before NAT)
                  client_ip = self.client_address[0]
                  
                  # Parse request path for additional info
                  parsed = urlparse(self.path)
                  query_params = parse_qs(parsed.query)
                  
                  # Prepare response
                  response_data = {
                      "source_ip": client_ip,
                      "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
                      "method": self.command,
                      "path": self.path,
                      "headers": dict(self.headers),
                      "server_hostname": socket.gethostname()
                  }
                  
                  # Add query parameters if present
                  if query_params:
                      response_data["query_params"] = query_params
                  
                  # Set response headers
                  self.send_response(200)
                  self.send_header('Content-type', 'application/json')
                  self.send_header('Access-Control-Allow-Origin', '*')
                  self.end_headers()
                  
                  # Send JSON response
                  response_json = json.dumps(response_data, indent=2)
                  self.wfile.write(response_json.encode('utf-8'))
              
              def log_message(self, format, *args):
                  # Custom log format showing client IP
                  print(f"[{datetime.datetime.utcnow().isoformat()}Z] {self.client_address[0]} - {format % args}")
          
          if __name__ == '__main__':
              port = 8080
              server = HTTPServer(('0.0.0.0', port), IPEchoHandler)
              print(f"Internal IP Echo Service starting on port {port}")
              print(f"Reports actual source IPs before NAT translation")
              server.serve_forever()
          PYEOF
          
          python3 /tmp/ipecho-server.py
        ports:
        - containerPort: 8080
          protocol: TCP
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 1001
          capabilities:
            drop:
            - ALL
          seccompProfile:
            type: RuntimeDefault
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: internal-ipecho
  namespace: egress-ip-validation
spec:
  selector:
    app: internal-ipecho
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
  type: ClusterIP
EOF

log_info "Waiting for internal IP echo service to be ready..."
if oc wait --for=condition=ready pod -l app=internal-ipecho -n egress-ip-validation --timeout=120s; then
    log_success "✅ Internal IP echo service deployed successfully"
else
    error_exit "Internal IP echo service failed to become ready"
fi

# Test the service
log_info "Testing internal IP echo service..."
SERVICE_IP=$(oc get service internal-ipecho -n egress-ip-validation -o jsonpath='{.spec.clusterIP}')
log_info "Service cluster IP: $SERVICE_IP"

# Create test pod to verify service works
cat << 'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ipecho-test
  namespace: egress-ip-validation
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: curl-test
    image: quay.io/openshift/origin-network-tools:latest
    command: ["/bin/sleep", "60"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 1001
      capabilities:
        drop:
        - ALL
      seccompProfile:
        type: RuntimeDefault
  restartPolicy: Never
EOF

if oc wait --for=condition=ready pod/ipecho-test -n egress-ip-validation --timeout=60s; then
    log_info "Testing internal IP echo service response..."
    TEST_RESPONSE=$(oc exec -n egress-ip-validation ipecho-test -- curl -s "http://internal-ipecho.egress-ip-validation.svc.cluster.local/" || echo "")
    
    if [[ -n "$TEST_RESPONSE" ]] && echo "$TEST_RESPONSE" | grep -q "source_ip"; then
        log_success "✅ Internal IP echo service is working correctly"
        log_info "Sample response: $TEST_RESPONSE"
        
        # Save service details for other test steps
        echo "http://internal-ipecho.egress-ip-validation.svc.cluster.local/" > "$SHARED_DIR/internal-ipecho-url"
        echo "$SERVICE_IP" > "$SHARED_DIR/internal-ipecho-cluster-ip"
        
        log_success "✅ Internal IP echo service URL saved to: $SHARED_DIR/internal-ipecho-url"
    else
        log_error "❌ Internal IP echo service test failed"
        log_error "Response: $TEST_RESPONSE"
        exit 1
    fi
else
    log_error "❌ Test pod failed to become ready"
    exit 1
fi

# Cleanup test pod
oc delete pod ipecho-test -n egress-ip-validation --ignore-not-found=true

log_success "🎉 Internal IP Echo Service deployment completed successfully!"
log_info "Service URL: http://internal-ipecho.egress-ip-validation.svc.cluster.local/"
log_info "This service will report actual source IPs before NAT translation for egress IP validation"