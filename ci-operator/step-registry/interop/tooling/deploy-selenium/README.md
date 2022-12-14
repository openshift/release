# interop-tooling-deploy-selenium-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
  - [Prepare](#prepare)
    - [Retrieve the console URL](#retrieve-the-console-url)
    - [Check if SELENIUM\_NAMESPACE is defined](#check-if-selenium_namespace-is-defined)
  - [Deploy](#deploy)
    - [Create the Namespace](#create-the-namespace)
    - [Deploy the Selenium Pod](#deploy-the-selenium-pod)
    - [Create a Service](#create-a-service)
    - [Create an Ingress](#create-an-ingress)
    - [Create a Network Policy](#create-a-network-policy)
  - [Verify](#verify)
- [Container Used](#container-used)
- [Requirements](#requirements)
  - [Variables](#variables)
  - [Infrastructure](#infrastructure)

## Purpose

To deploy a Selenium pod, along with the network infrastructure to use it from a different cluster, to the target test cluster. The container uses the [quay.io/redhatqe/selenium-standalone](https://quay.io/repository/redhatqe/selenium-standalone) image and allows us to use the container as a remote executor for Selenium tests.

## Process

This script can be separated into three parts: prepare, deploy, and verify.

### Prepare

#### Retrieve the console URL
The following snippet is used to retrieve the console URL. We only use this during the [Verify](#verify) step of this script. It is used to build the URL to request the status of the pod.

```bash
URL=$(oc get route -n openshift-console console -o jsonpath='{.spec.host}')
APPS_URL=${URL#"console-openshift-console."}
```

#### Check if SELENIUM_NAMESPACE is defined
The following snippet is used to verify that the `SELENIUM_NAMESPACE` environment variable is defined. If it is not defined, the default namespace of `selenium` will be used.

```bash
if [[ -z "${SELENIUM_NAMESPACE}" ]]; then
  echo "SELENIUM_NAMESPACE is not defined, using \"selenium\""
  SELENIUM_NAMESPACE="selenium"
fi
```

### Deploy

#### Create the Namespace

The following snippet is used to create the Namespace defined in the `SELENIUM_NAMESPACE` variable. This command is idempotent, if the Namespace already exists, it will move on.

```bash
echo "Creating namespace ${SELENIUM_NAMESPACE}"
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${SELENIUM_NAMESPACE}"
EOF
```

#### Deploy the Selenium Pod

The following snippet deploys the Selenium pod with the resources required to run this pod. It should pull a new image from Quay every time it is deployed, so the image will stay up to date.

```bash
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
```

#### Create a Service

The following snippet is used to create the Selenium service that will route traffic from the Ingress (port 80) to the Selenium pod (port 4444). 

```bash
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
```

#### Create an Ingress

The following snippet creates an Ingress on the target test cluster to allow for traffic from outside of the cluster to reach the Selenium pod.

```bash
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
```

#### Create a Network Policy

The following snippet creates the Network Policy that allows Ingress to our Selenium pod from outside of the network.

```bash
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
```

### Verify

The following snippet waits about 2.5 minutes for the pod to finish starting, then checks the status of the pod and the network. It will print the output of this check, then write the address needed to use the pod as a remote executor to a file named `selenium-executor` in the `SHARED_DIR` for use in later stages of testing.

```bash
echo "Waiting for Selenium contianer to start..."
sleep 150

selenium_status=$(curl http://selenium-${SELENIUM_NAMESPACE}.${APPS_URL}/wd/hub/status)
echo "SELENIUM STATUS:"
echo $selenium_status

echo "selenium-${SELENIUM_NAMESPACE}.${APPS_URL}:80" > ${SHARED_DIR}/selenium-executor
```

## Container Used

The container used to execute this step is the built-in `cli`image.

## Requirements

### Variables

- `SELENIUM_NAMESPACE`
  - **Definition**: The namespace that the Selenium pod and the supporting network infrastructure will be deployed in.
  - **If left empty**: The script will use the `selenium` namespace.
  - **Additional information**: If the requested namespace does not exist, it will be created.

### Infrastructure

- A provisioned test cluster to target.