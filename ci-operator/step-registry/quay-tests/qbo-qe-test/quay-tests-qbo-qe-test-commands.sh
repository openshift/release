#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Install QBO
QBO_CHANNEL="$QBO_CHANNEL"
QBO_SOURCE="$QBO_SOURCE"

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-bridge-operator
  namespace: openshift-operators
spec:
  channel: $QBO_CHANNEL
  installPlanApproval: Automatic
  name: quay-bridge-operator
  source: $QBO_SOURCE
  sourceNamespace: openshift-marketplace
EOF

for _ in {1..60}; do
    CSV=$(oc -n openshift-operators get sub quay-bridge-operator -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n openshift-operators get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"$CSV\" ready"
            break
        fi
    fi
    echo "CSV is NOT ready $_ times"
    sleep 10
done
echo "Quay Bridge Operator is deployed successfully"


#execute sanity test
##Creating OAuth application and token
token=$(set +o pipefail; LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 40)
quay_ns=$(oc get quayregistry --all-namespaces | tail -n1 | tr " " "\n" | head -n1)
quay_registry=$(oc get quayregistry -n "$quay_ns" | tail -n1 | tr " " "\n" | head -n1)
quay_app_pod=$(oc -n "$quay_ns" get pods -l quay-component=quay-app -o name | head -n1)

oc -n "$quay_ns" rsh "$quay_app_pod" python <<EOF
from app import app
from data import model
from data.database import configure

if hasattr(model.oauth, 'create_user_access_token'):
    create_user_access_token = model.oauth.create_user_access_token
else:
    create_user_access_token = model.oauth.create_access_token_for_testing

scope="org:admin repo:admin repo:create repo:read repo:write super:user user:admin user:read"

configure(app.config)

admin_user = model.user.create_user("admin", "p@ssw0rd", "admin@localhost.local", auto_verify=True)
operator_org = model.organization.create_organization("quay-bridge-operator", "quay-bridge-operator@localhost.local", admin_user)
operator_app = model.oauth.create_application(operator_org.id, "quay-bridge-operator", "", "")
create_user_access_token(admin_user, operator_app.client_id, scope, access_token="$token")
EOF

##Redeploy quay pod
oc delete pods -n "$quay_ns" -l quay-component=quay-app

for _ in {1..60}; do
    quay_pod_status=$(oc -n "$quay_ns" get pods -l quay-component=quay-app -o go-template='{{$x := ""}}{{range .items}}{{range .status.conditions}}{{if eq .type "Ready"}}{{if or (eq $x "") (eq .status "False")}}{{$x = .status}}{{end}}{{end}}{{end}}{{end}}{{or $x "False"}}')
    if [ "$quay_pod_status" = "True" ]; then
        printf "%s" "$token" >"$SHARED_DIR/quay-access-token"
        echo "Quay is running" >&2
        break
    fi
    echo "Quay Pod is NOT ready $_ times"
    sleep 10
done

##Create QuayIntegration CR
oc create secret -n openshift-operators generic quay-integration --from-file=token="$SHARED_DIR/quay-access-token"

registryEndpoint="$(oc -n "$quay_ns" get quayregistry "$quay_registry" -o jsonpath='{.status.registryEndpoint}')"
registry="${registryEndpoint#https://}"

cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayIntegration
metadata:
  name: quay
spec:
  clusterID: openshift
  credentialsSecret:
    namespace: openshift-operators
    name: quay-integration
  quayHostname: $registryEndpoint
EOF

##Add quay certificate to openshift
quay_cert="$(oc get cm -n openshift-apiserver kube-root-ca.crt -o jsonpath='{.data.ca\.crt}')"
printf "%s" "$quay_cert" >"$SHARED_DIR/quay.crt"
oc create configmap registry-cas -n openshift-config --from-file=$registry="$SHARED_DIR/quay.crt"
oc patch image.config.openshift.io/cluster --patch '{"spec":{"additionalTrustedCA":{"name":"registry-cas"}}}' --type=merge
sleep 10
time oc wait mcp --for=condition=Updated --all --timeout=20m

##create ns
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: test-qbo
EOF

##Create an app from template
cat <<EOF | oc apply -f -
kind: Template
apiVersion: template.openshift.io/v1
metadata:
  name: rails-postgresql-example
  namespace: test-qbo
  annotations:
    openshift.io/display-name: Rails + PostgreSQL (Ephemeral)
    description: |-
      An example Rails application with a PostgreSQL database. For more information about using this template, including OpenShift considerations, see https://github.com/sclorg/rails-ex/blob/master/README.md.

      WARNING: Any data stored will be lost upon pod destruction. Only use this template for testing.
    tags: quickstart,ruby,rails
    iconClass: icon-ruby
    openshift.io/long-description: This template defines resources needed to develop
      a Rails application, including a build configuration, application deployment
      configuration, and database deployment configuration.  The database is stored
      in non-persistent storage, so this configuration should be used for experimental
      purposes only.
    openshift.io/provider-display-name: Red Hat, Inc.
    openshift.io/documentation-url: https://github.com/sclorg/rails-ex
    openshift.io/support-url: https://access.redhat.com
    template.openshift.io/bindable: 'false'
message: |-
  The following service(s) have been created in your project: \${NAME}, \${DATABASE_SERVICE_NAME}.

  For more information about using this template, including OpenShift considerations, see https://github.com/sclorg/rails-ex/blob/master/README.md.
labels:
  template: rails-postgresql-example
  app: rails-postgresql-example
objects:
- kind: Secret
  apiVersion: v1
  metadata:
    name: "\${NAME}"
  stringData:
    database-user: "\${DATABASE_USER}"
    database-password: "\${DATABASE_PASSWORD}"
    application-user: "\${APPLICATION_USER}"
    application-password: "\${APPLICATION_PASSWORD}"
    keybase: "\${SECRET_KEY_BASE}"
- kind: Service
  apiVersion: v1
  metadata:
    name: "\${NAME}"
    annotations:
      description: Exposes and load balances the application pods
      service.alpha.openshift.io/dependencies: '[{"name": "\${DATABASE_SERVICE_NAME}",
        "kind": "Service"}]'
  spec:
    ports:
    - name: web
      port: 8080
      targetPort: 8080
    selector:
      name: "\${NAME}"
- kind: Route
  apiVersion: route.openshift.io/v1
  metadata:
    name: "\${NAME}"
  spec:
    host: "\${APPLICATION_DOMAIN}"
    to:
      kind: Service
      name: "\${NAME}"
- kind: ImageStream
  apiVersion: image.openshift.io/v1
  metadata:
    name: "\${NAME}"
    annotations:
      description: Keeps track of changes in the application image
- kind: BuildConfig
  apiVersion: build.openshift.io/v1
  metadata:
    name: "\${NAME}"
    annotations:
      description: Defines how to build the application
      template.alpha.openshift.io/wait-for-ready: 'true'
  spec:
    source:
      type: Git
      git:
        uri: "\${SOURCE_REPOSITORY_URL}"
        ref: "\${SOURCE_REPOSITORY_REF}"
      contextDir: "\${CONTEXT_DIR}"
    strategy:
      type: Source
      sourceStrategy:
        from:
          kind: ImageStreamTag
          namespace: "\${NAMESPACE}"
          name: ruby:2.7-ubi8
        env:
        - name: RUBYGEM_MIRROR
          value: "\${RUBYGEM_MIRROR}"
    output:
      to:
        kind: ImageStreamTag
        name: "\${NAME}:latest"
    triggers:
    - type: ImageChange
    - type: ConfigChange
    - type: GitHub
      github:
        secret: "\${GITHUB_WEBHOOK_SECRET}"
    postCommit:
      script: bundle exec rake test
- kind: DeploymentConfig
  apiVersion: apps.openshift.io/v1
  metadata:
    name: "\${NAME}"
    annotations:
      description: Defines how to deploy the application server
      template.alpha.openshift.io/wait-for-ready: 'true'
  spec:
    strategy:
      type: Recreate
      recreateParams:
        pre:
          failurePolicy: Abort
          execNewPod:
            command:
            - "./migrate-database.sh"
            containerName: "\${NAME}"
    triggers:
    - type: ImageChange
      imageChangeParams:
        automatic: true
        containerNames:
        - "\${NAME}"
        from:
          kind: ImageStreamTag
          name: "\${NAME}:latest"
    - type: ConfigChange
    replicas: 1
    selector:
      name: "\${NAME}"
    template:
      metadata:
        name: "\${NAME}"
        labels:
          name: "\${NAME}"
      spec:
        containers:
        - name: "\${NAME}"
          image: " "
          ports:
          - containerPort: 8080
          readinessProbe:
            timeoutSeconds: 3
            initialDelaySeconds: 5
            httpGet:
              path: "/articles"
              port: 8080
          livenessProbe:
            timeoutSeconds: 3
            initialDelaySeconds: 10
            httpGet:
              path: "/articles"
              port: 8080
          env:
          - name: DATABASE_SERVICE_NAME
            value: "\${DATABASE_SERVICE_NAME}"
          - name: POSTGRESQL_USER
            valueFrom:
              secretKeyRef:
                name: "\${NAME}"
                key: database-user
          - name: POSTGRESQL_PASSWORD
            valueFrom:
              secretKeyRef:
                name: "\${NAME}"
                key: database-password
          - name: POSTGRESQL_DATABASE
            value: "\${DATABASE_NAME}"
          - name: SECRET_KEY_BASE
            valueFrom:
              secretKeyRef:
                name: "\${NAME}"
                key: keybase
          - name: POSTGRESQL_MAX_CONNECTIONS
            value: "\${POSTGRESQL_MAX_CONNECTIONS}"
          - name: POSTGRESQL_SHARED_BUFFERS
            value: "\${POSTGRESQL_SHARED_BUFFERS}"
          - name: APPLICATION_DOMAIN
            value: "\${APPLICATION_DOMAIN}"
          - name: APPLICATION_USER
            valueFrom:
              secretKeyRef:
                name: "\${NAME}"
                key: application-user
          - name: APPLICATION_PASSWORD
            valueFrom:
              secretKeyRef:
                name: "\${NAME}"
                key: application-password
          - name: RAILS_ENV
            value: "\${RAILS_ENV}"
          resources:
            limits:
              memory: "\${MEMORY_LIMIT}"
- kind: Service
  apiVersion: v1
  metadata:
    name: "\${DATABASE_SERVICE_NAME}"
    annotations:
      description: Exposes the database server
  spec:
    ports:
    - name: postgresql
      port: 5432
      targetPort: 5432
    selector:
      name: "\${DATABASE_SERVICE_NAME}"
- kind: DeploymentConfig
  apiVersion: apps.openshift.io/v1
  metadata:
    name: "\${DATABASE_SERVICE_NAME}"
    annotations:
      description: Defines how to deploy the database
      template.alpha.openshift.io/wait-for-ready: 'true'
  spec:
    strategy:
      type: Recreate
    triggers:
    - type: ImageChange
      imageChangeParams:
        automatic: true
        containerNames:
        - postgresql
        from:
          kind: ImageStreamTag
          namespace: "\${NAMESPACE}"
          name: postgresql:12-el8
    - type: ConfigChange
    replicas: 1
    selector:
      name: "\${DATABASE_SERVICE_NAME}"
    template:
      metadata:
        name: "\${DATABASE_SERVICE_NAME}"
        labels:
          name: "\${DATABASE_SERVICE_NAME}"
      spec:
        volumes:
        - name: data
          emptyDir: {}
        containers:
        - name: postgresql
          image: " "
          ports:
          - containerPort: 5432
          readinessProbe:
            timeoutSeconds: 1
            initialDelaySeconds: 5
            exec:
              command:
              - "/usr/libexec/check-container"
          livenessProbe:
            timeoutSeconds: 10
            initialDelaySeconds: 120
            exec:
              command:
              - "/usr/libexec/check-container"
              - "--live"
          volumeMounts:
          - name: data
            mountPath: "/var/lib/pgsql/data"
          env:
          - name: POSTGRESQL_USER
            valueFrom:
              secretKeyRef:
                name: "\${NAME}"
                key: database-user
          - name: POSTGRESQL_PASSWORD
            valueFrom:
              secretKeyRef:
                name: "\${NAME}"
                key: database-password
          - name: POSTGRESQL_DATABASE
            value: "\${DATABASE_NAME}"
          - name: POSTGRESQL_MAX_CONNECTIONS
            value: "\${POSTGRESQL_MAX_CONNECTIONS}"
          - name: POSTGRESQL_SHARED_BUFFERS
            value: "\${POSTGRESQL_SHARED_BUFFERS}"
          resources:
            limits:
              memory: "\${MEMORY_POSTGRESQL_LIMIT}"
parameters:
- name: NAME
  displayName: Name
  description: The name assigned to all of the frontend objects defined in this template.
  required: true
  value: rails-postgresql-example
- name: NAMESPACE
  displayName: Namespace
  required: true
  description: The OpenShift Namespace where the ImageStream resides.
  value: openshift
- name: MEMORY_LIMIT
  displayName: Memory Limit
  required: true
  description: Maximum amount of memory the Rails container can use.
  value: 512Mi
- name: MEMORY_POSTGRESQL_LIMIT
  displayName: Memory Limit (PostgreSQL)
  required: true
  description: Maximum amount of memory the PostgreSQL container can use.
  value: 512Mi
- name: SOURCE_REPOSITORY_URL
  displayName: Git Repository URL
  required: true
  description: The URL of the repository with your application source code.
  value: https://github.com/sclorg/rails-ex.git
- name: SOURCE_REPOSITORY_REF
  displayName: Git Reference
  description: Set this to a branch name, tag or other ref of your repository if you
    are not using the default branch.
- name: CONTEXT_DIR
  displayName: Context Directory
  description: Set this to the relative path to your project if it is not in the root
    of your repository.
- name: APPLICATION_DOMAIN
  displayName: Application Hostname
  description: The exposed hostname that will route to the Rails service, if left
    blank a value will be defaulted.
  value: ''
- name: GITHUB_WEBHOOK_SECRET
  displayName: GitHub Webhook Secret
  description: Github trigger secret.  A difficult to guess string encoded as part
    of the webhook URL.  Not encrypted.
  generate: expression
  from: "[a-zA-Z0-9]{40}"
- name: SECRET_KEY_BASE
  displayName: Secret Key
  description: Your secret key for verifying the integrity of signed cookies.
  generate: expression
  from: "[a-z0-9]{127}"
- name: APPLICATION_USER
  displayName: Application Username
  required: true
  description: The application user that is used within the sample application to
    authorize access on pages.
  value: openshift
- name: APPLICATION_PASSWORD
  displayName: Application Password
  required: true
  description: The application password that is used within the sample application
    to authorize access on pages.
  value: secret
- name: RAILS_ENV
  displayName: Rails Environment
  required: true
  description: Environment under which the sample application will run. Could be set
    to production, development or test.
  value: production
- name: DATABASE_SERVICE_NAME
  required: true
  displayName: Database Service Name
  value: postgresql
- name: DATABASE_USER
  displayName: Database Username
  generate: expression
  from: user[A-Z0-9]{3}
- name: DATABASE_PASSWORD
  displayName: Database Password
  generate: expression
  from: "[a-zA-Z0-9]{8}"
- name: DATABASE_NAME
  required: true
  displayName: Database Name
  value: root
- name: POSTGRESQL_MAX_CONNECTIONS
  displayName: Maximum Database Connections
  value: '100'
- name: POSTGRESQL_SHARED_BUFFERS
  displayName: Shared Buffer Amount
  value: 12MB
- name: RUBYGEM_MIRROR
  displayName: Custom RubyGems Mirror URL
  description: The custom RubyGems mirror URL
  value: ''
EOF

oc project test-qbo
oc new-app rails-postgresql-example
for _ in {1..30}; do
  build_status=$(oc -n test-qbo get build -l buildconfig=rails-postgresql-example -o go-template='{{$x := ""}}{{range .items}}{{range .status.conditions}}{{if eq .type "Complete"}}{{if or (eq $x "") (eq .status "False")}}{{$x = .status}}{{end}}{{end}}{{end}}{{end}}{{or $x "False"}}')
  if [ "$build_status" = "True" ]; then
    echo "Build image push to quay successfully"
    break
  fi
  echo "Build is NOT ready $_ times"
  sleep 60
done

for _ in {1..30}; do
  app_status=$(oc -n test-qbo get pods -l deploymentconfig=rails-postgresql-example -o go-template='{{$x := ""}}{{range .items}}{{range .status.conditions}}{{if eq .type "Ready"}}{{if or (eq $x "") (eq .status "False")}}{{$x = .status}}{{end}}{{end}}{{end}}{{end}}{{or $x "False"}}')
  if [ "$app_status" = "True" ]; then
    echo "App pod pull image from quay successfully"
    break
  fi
  echo "App pod is NOT ready $_ times"
  sleep 20
done
echo "QE Test for Quay Bridge Operator is passed"
