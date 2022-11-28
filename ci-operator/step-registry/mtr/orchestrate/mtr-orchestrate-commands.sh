#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Get the apps URL and pass it to env.sh for the mtr-runner container to use
URL=$(oc get route -n openshift-console console -o jsonpath='{.spec.host}')
APPS_URL=${URL#"console-openshift-console."}
echo "APPS_URL=${APPS_URL}"
echo "export APPS_URL=${APPS_URL}" >> ${SHARED_DIR}/env.sh
chmod +x ${SHARED_DIR}/env.sh

# Deploy windup
echo "Deploying Windup"
oc apply -f - <<EOF
apiVersion: windup.jboss.org/v1
kind: Windup
metadata:
    name: mtr
    namespace: mtr
    labels:
      application: mtr
spec:
    volumeCapacity: "5Gi"
EOF

# Wait 5 minutes for Windup to fully deploy
echo "Waiting 5 minutes for Windup to finish deploying"
sleep 300
echo "Windup operator installed and Windup deployed."

# Deploy the Selenium pod and it's infrascructure
echo "Deploying the Selenium pod..."
oc apply -f - <<EOF
kind: Pod
apiVersion: v1
metadata:
  name: selenium-runner
  namespace: mtr
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
oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: selenium
  namespace: mtr
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
oc apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: selenium-ingress
  namespace: mtr
  labels:
    app: selenium
spec:
  rules:
    - host: selenium-mtr.${APPS_URL}
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
oc apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: selenium
  namespace: mtr
spec:
  podSelector:
    matchLabels:
      app: selenium
  policyTypes:
    - Ingress
  ingress:
    - {}
EOF

echo "Waiting for Selenium contianer to start"
sleep 150

selenium_status=$(curl http://selenium-mtr.${APPS_URL}/wd/hub/status)
echo "SELENIUM STATUS:"
echo $selenium_status