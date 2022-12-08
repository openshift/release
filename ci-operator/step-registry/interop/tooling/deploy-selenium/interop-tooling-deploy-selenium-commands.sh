#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

URL=$(oc get route -n openshift-console console -o jsonpath='{.spec.host}')
APPS_URL=${URL#"console-openshift-console."}

if [[ -z "${SELENIUM_NAMESPACE}" ]]; then
  echo "SELENIUM_NAMESPACE is not defined, using \"selenium\""
  SELENIUM_NAMESPACE="selenium"
fi

# Create the namespace
echo "Creating namespace ${SELENIUM_NAMESPACE}"
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${SELENIUM_NAMESPACE}"
EOF

# Deploy the Selenium pod and it's infrascructure
echo "Deploying the Selenium pod..."
oc apply -f - <<EOF
kind: Pod
apiVersion: v1
metadata:
  name: selenium-runner
  namespace: "${SELENIUM_NAMESPACE}"
  labels:
    app: selenium
spec:
  containers:
    - resources:
        limits:
          cpu: '1'
          memory: 3Gi
        requests:
          cpu: '1'
          memory: 3Gi
      terminationMessagePath: /dev/termination-log
      name: selenium
      imagePullPolicy: Always
      volumeMounts:
        - name: shm
          mountPath: /dev/shm
      terminationMessagePolicy: File
      image: 'quay.io/redhatqe/selenium-standalone:latest'
      env:
        - name: SELENIUM_PORT
          value: "4444"
  volumes:
    - name: shm
      emptyDir:
        medium: Memory
        sizeLimit: 2Gi
EOF

# Create a new service for selenium
echo "Creating selenium service..."
oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: selenium
  namespace: "${SELENIUM_NAMESPACE}"
  labels:
    app: selenium
spec:
  selector:
    app: selenium
  ports:
    - name: web
      protocol: TCP
      port: 4444
      targetPort: 4444
EOF

# Create ingress route to service
echo "Creating selenium ingress"
oc apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: selenium-ingress
  namespace: "${SELENIUM_NAMESPACE}"
  labels:
    app: selenium
spec:
  rules:
    - host: selenium-${SELENIUM_NAMESPACE}.${APPS_URL}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: selenium
                port:
                  number: 4444
EOF

# Create an ingress rule
echo "Adding network policy for selenium ingress..."
oc apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: selenium
  namespace: "${SELENIUM_NAMESPACE}"
spec:
  podSelector:
    matchLabels:
      app: selenium
  policyTypes:
    - Ingress
  ingress:
    - {}
EOF

echo "Waiting for Selenium contianer to start..."
sleep 150

selenium_status=$(curl http://selenium-${SELENIUM_NAMESPACE}.${APPS_URL}/wd/hub/status)
echo "SELENIUM STATUS:"
echo $selenium_status

echo "selenium-${SELENIUM_NAMESPACE}.${APPS_URL}:80" > ${SHARED_DIR}/selenium-executor