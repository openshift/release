#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function create_foo_project_and_policies()
{
  oc new-project jboss-fuse-interop
  oc label --overwrite ns ${1} pod-security.kubernetes.io/enforce=privileged
  oc label --overwrite ns ${1} pod-security.kubernetes.io/enforce-version-
  oc adm policy add-scc-to-user privileged -z default -n ${1}
}

function create_foo_configmaps()
{
  REGISTRY_REDHAT_IO_AUTH=$(cat /tmp/secrets/foo-qe/registry-redhat-io-auth-secret)
  QUAY_IO_AUTH=$(cat /tmp/secrets/foo-qe/quay-io-auth-secret)
  CONSOLE_URL=$(cat $SHARED_DIR/console.url)
  API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
  NGINX_DOMAIN="nginx.${CONSOLE_URL#"https://console-openshift-console."}"
  KUBEADMIN_PWD=$(cat $SHARED_DIR/kubeadmin-password)


  export REGISTRY_REDHAT_IO_AUTH
  export QUAY_IO_AUTH
  export API_URL
  export KUBEADMIN_PWD

  cat << EOF > /tmp/settings.xml
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
		xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
		xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 http://maven.apache.org/xsd/settings-1.0.0.xsd">
	<localRepository>/deployments/.m2/repository</localRepository>
	<servers>
  		<server>
  			<id>maven</id>
  		</server>
  	</servers>

  	<profiles>
  		<profile>
  			<id>redhat-ga-repository</id>
  			<repositories>
  				<repository>
  					<id>jboss-ga-repository</id>
  					<url>https://maven.repository.redhat.com/ga/</url>
  					<releases>
  						<enabled>true</enabled>
  						<updatePolicy>never</updatePolicy>
  					</releases>
  					<snapshots>
  						<enabled>false</enabled>
  						<updatePolicy>never</updatePolicy>
  					</snapshots>
  				</repository>
  				<repository>
            <id>custom-mvn-repo</id>
            <url>http://${NGINX_DOMAIN}/</url>
            <snapshots>
              <enabled>true</enabled>
              <updatePolicy>never</updatePolicy>
            </snapshots>
            <releases>
              <enabled>true</enabled>
              <updatePolicy>never</updatePolicy>
            </releases>
          </repository>
  			</repositories>
  			<pluginRepositories>
  				<pluginRepository>
  					<id>jboss-ga-plugin-repository</id>
  					<url>https://maven.repository.redhat.com/ga/</url>
  					<releases>
  						<enabled>true</enabled>
  						<updatePolicy>never</updatePolicy>
  					</releases>
  					<snapshots>
  						<enabled>false</enabled>
  						<updatePolicy>never</updatePolicy>
  					</snapshots>
  				</pluginRepository>
  				<pluginRepository>
            <id>custom-plugin-repo</id>
              <url>http://${NGINX_DOMAIN}/</url>
              <snapshots>
                <enabled>true</enabled>
                <updatePolicy>never</updatePolicy>
              </snapshots>
              <releases>
                <enabled>true</enabled>
                <updatePolicy>never</updatePolicy>
              </releases>
            </pluginRepository>
  			</pluginRepositories>
  		</profile>
  		<profile>
  			<id>redhat-ea-repository</id>
  			<repositories>
  				<repository>
  					<id>jboss-ea-repository</id>
  					<url>https://maven.repository.redhat.com/earlyaccess/all/</url>
  					<releases>
  						<enabled>true</enabled>
  						<updatePolicy>never</updatePolicy>
  					</releases>
  					<snapshots>
  						<enabled>false</enabled>
  						<updatePolicy>never</updatePolicy>
  					</snapshots>
  				</repository>
  			</repositories>
  			<pluginRepositories>
  			  <pluginRepository>
          	<id>custom-plugin-repo</id>
          	<url>http://${NGINX_DOMAIN}/</url>
          	<snapshots>
          		<enabled>true</enabled>
          		<updatePolicy>never</updatePolicy>
          	</snapshots>
          	<releases>
          		<enabled>true</enabled>
          		<updatePolicy>never</updatePolicy>
          	</releases>
          </pluginRepository>
  				<pluginRepository>
  					<id>jboss-ga-plugin-repository</id>
  					<url>https://maven.repository.redhat.com/earlyaccess/all/</url>
  					<releases>
  						<enabled>true</enabled>
  						<updatePolicy>never</updatePolicy>
  					</releases>
  					<snapshots>
  						<enabled>false</enabled>
  						<updatePolicy>never</updatePolicy>
  					</snapshots>
  				</pluginRepository>
  			</pluginRepositories>
  		</profile>

  	</profiles>

  	<activeProfiles>
  		<activeProfile>redhat-ga-repository</activeProfile>
  		<activeProfile>redhat-ea-repository</activeProfile>
  	</activeProfiles>
</settings>
EOF

 cat << EOF > /tmp/test.properties
xtf.config.delete.namespace=true
xtf.config.oreg.registry=registry.redhat.io
xtf.config.oreg.auth=$REGISTRY_REDHAT_IO_AUTH
xtf.config.quay.registry=quay.io
xtf.config.quay.auth=$QUAY_IO_AUTH
xtf.openshift.admin.username=kubeadmin
xtf.openshift.admin.password=$KUBEADMIN_PWD
xtf.openshift.master.username=kubeadmin
xtf.openshift.master.password=$KUBEADMIN_PWD
xtf.openshift.url=$API_URL
xtf.local.prebuild=true
xtf.config.gitlab=false
xtf.custom.mirror.url=http://${NGINX_DOMAIN}
xtf.maven.proxy.group=fis-central-ga-ea
xtf.openshift.binary.url.channel=latest
test.docker.registry=registry.ci.openshift.org/ci
EOF

  oc create configmap mvn-settings -n ${1} --from-file=/tmp/settings.xml
  oc create secret generic test-properties -n ${1} --from-file=/tmp/test.properties
}

function create_foo_volumes()
{
  oc create -f - <<EOF
kind: PersistentVolume
apiVersion: v1
metadata:
  name: postgresql-persistent
  labels:
    app: postgresql-persistent
    type: local
spec:
  storageClassName: manual
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Recycle
  hostPath:
    path: "/mnt"
EOF

oc create -f - <<EOF
kind: PersistentVolume
apiVersion: v1
metadata:
  name: persistent-fuse-1
  labels:
    type: local
    application: xpaas-qe
spec:
  storageClassName: manual
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteOnce
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Recycle
  hostPath:
    path: "/mnt"
EOF

  oc create -f - <<EOF
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: persistent-xpaas-qe
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 19Gi
  selector:
    matchLabels:
      application: xpaas-qe
  storageClassName: manual
  volumeMode: Filesystem
EOF
}

function create_nginx() {
  NGINX_DOMAIN="nginx.${CONSOLE_URL#"https://console-openshift-console."}"
  NGINX_HOST=${NGINX_DOMAIN//".org/"/.org}
  export NGINX_HOST

  oc import-image ${1}/nginx:latest --from=quay.io/packit/nginx-unprivileged --confirm -n ${1}
  oc create -f - <<EOF
kind: ConfigMap
apiVersion: v1
metadata:
  name: nginx-conf
data:
  default.conf: |
    server {
        listen       8080;
        server_name  localhost;

        location / {
            autoindex on;
            root   /deployments/.m2/repository;
            index  index.html index.htm;
        }

        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   /deployments/.m2/repository;
        }
    }
EOF

  oc create -f - <<EOF
kind: Deployment
apiVersion: apps/v1
metadata:
  name: nginx-server
  namespace: ${1}
  annotations:
    image.openshift.io/triggers: '[{"from":{"kind":"ImageStreamTag","name":"nginx:latest"},"fieldPath":"spec.template.spec.containers[?(@.name==\"nginx\")].image"}]'
  labels:
    application: xpaas-qe
    deployment: nginx
spec:
  strategy:
    type: Recreate
  triggers:
    - type: ImageChange
      imageChangeParams:
        automatic: true
        containerNames:
          - nginx
        from:
          kind: ImageStreamTag
          name: nginx:latest
    - type: ConfigChange
  replicas: 1
  selector:
    matchLabels:
      deployment: nginx
  template:
    metadata:
      name: nginx
      labels:
        deployment: nginx
        application: xpaas-qe
    spec:
      securityContext:
        runAsUser: 0
      terminationGracePeriodSeconds: 60
      volumes:
        - name: nginx-settings
          configMap:
            name: nginx-conf
            items:
              - key: default.conf
                path: default.conf
        - name: xpaas-qe-volume
          persistentVolumeClaim:
            claimName: persistent-xpaas-qe
      containers:
        - name: nginx
          image: nginx:latest
          ports:
            - containerPort: 22
              protocol: TCP
            - containerPort: 80
              protocol: TCP
            - containerPort: 443
              protocol: TCP
          securityContext:
            privileged: true
          volumeMounts:
            - name: nginx-settings
              mountPath: /etc/nginx/conf.d/
              readOnly: true
            - name: xpaas-qe-volume
              mountPath: /deployments/.m2/
              subPath: maven-repo
            - name: xpaas-qe-volume
              mountPath: /tmp/surefire-reports/
              subPath: surefire-reports
            - name: xpaas-qe-volume
              mountPath: /tmp/log/
              subPath: log
            - name: xpaas-qe-volume
              mountPath: /tmp/reports
              subPath: reports
            - name: xpaas-qe-volume
              mountPath: /tmp/tests
              subPath: tests
EOF

  oc create -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nginx
  labels:
    application: xpaas-qe
spec:
  externalTrafficPolicy: Local
  ports:
  - name: http
    port: 8080
    protocol: TCP
    targetPort: 8080
  selector:
    deployment: nginx
  type: NodePort
EOF

  oc expose svc/nginx --hostname=${NGINX_HOST}

}

echo "Create project"
create_foo_project_and_policies jboss-fuse-interop

echo "Create persistent volumes"
create_foo_volumes

echo "Create configmaps"
create_foo_configmaps jboss-fuse-interop

echo "Create nginx server"
create_nginx jboss-fuse-interop

echo "Create xpaas-qe image stream"
oc import-image xpaas-qe:latest --from=quay.io/rh_integration/xpaas-qe:${FUSE_RELEASE} -n jboss-fuse-interop --confirm
