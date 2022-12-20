#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Retrieve the console URL. Used later in the script to build the URL to request the status of the pod.
URL=$(oc get route -n openshift-console console -o jsonpath='{.spec.host}')
APPS_URL=${URL#"console-openshift-console."}

# Verify that the `SELENIUM_NAMESPACE` environment variable is defined. 
# If it is not defined, the default namespace of `selenium` will be used.
if [[ -z "${SELENIUM_NAMESPACE}" ]]; then
  echo "SELENIUM_NAMESPACE is not defined, using \"selenium\""
  SELENIUM_NAMESPACE="selenium"
fi

# Create the Namespace defined in the `SELENIUM_NAMESPACE` variable. 
# This command is idempotent, if the Namespace already exists, it will move on.
echo "Creating namespace ${SELENIUM_NAMESPACE}"
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${SELENIUM_NAMESPACE}"
EOF

# Deploys the Selenium pod with the resources required to run this pod. 
# It should pull a new image from Quay every time it is deployed, so the image will stay up to date.
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

# Create the Selenium service that will route traffic from the Ingress (port 80) to the Selenium pod (port 4444). 
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

# Creates an Ingress on the target test cluster to allow for traffic from outside of the cluster to reach the Selenium pod.
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

# Creates the Network Policy that allows Ingress to our Selenium pod from outside of the network.
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

# Waits about 2.5 minutes for the pod to finish starting, then checks the status of the pod and the network. 
#It will print the output of this check, then write the address needed to use the pod as a remote executor to a file 
# named `selenium-executor` in the `SHARED_DIR` for use in later stages of testing.
echo "Waiting for Selenium contianer to start..."
sleep 150

selenium_status=$(curl http://selenium-${SELENIUM_NAMESPACE}.${APPS_URL}/wd/hub/status)
echo "SELENIUM STATUS:"
echo $selenium_status

echo "selenium-${SELENIUM_NAMESPACE}.${APPS_URL}:80" > ${SHARED_DIR}/selenium-executor