#!/bin/bash

set +u
set -o errexit
set -o pipefail

function create_csb_project_and_policies()
{
  oc new-project csb-interop
  oc label --overwrite ns "${1}" pod-security.kubernetes.io/enforce=privileged
  oc label --overwrite ns "${1}" pod-security.kubernetes.io/enforce-version-
  oc adm policy add-scc-to-user privileged -z default -n "${1}"
}

function create_csb_configmaps()
{
  CONSOLE_URL=$(cat "$SHARED_DIR"/console.url)
  API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
  NGINX_DOMAIN="nginx.${CONSOLE_URL#"https://console-openshift-console."}"
  KUBEADMIN_PWD=$(cat "$SHARED_DIR"/kubeadmin-password)
  NGINX_ROUTE="http://${NGINX_DOMAIN}"

  export QUAY_IO_AUTH
  export API_URL
  export KUBEADMIN_PWD
  export NGINX_ROUTE

  cat << EOF > /tmp/settings.xml
<settings
        xmlns="http://maven.apache.org/SETTINGS/1.0.0"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                                http://maven.apache.org/xsd/settings-1.0.0.xsd">
    <localRepository>/deployments/.m2/repository</localRepository>
    <interactiveMode/>
    <usePluginRegistry/>
    <offline/>
    <pluginGroups/>
    <servers/>
    <proxies/>
    <profiles>
        <!--
             The Order is very important. The one that is 1st in settings.xml is put at last when multiple
             profile repositories are activated.
         -->
        <profile>
            <id>repo.sap-internal</id>
            <activation>
                <activeByDefault>false</activeByDefault>
                <property>
                    <name>repo.sap-internal</name>
                </property>
            </activation>
            <repositories>
                <repository>
                    <id>sap-internal</id>
                    <name>SAP for internal use only</name>
                    <url>${NGINX_ROUTE}/sap-internal/</url>
                    <snapshots>
                        <enabled>false</enabled>
			                  <updatePolicy>never</updatePolicy>
                    </snapshots>
                    <releases>
                        <enabled>true</enabled>
			                  <updatePolicy>never</updatePolicy>
                    </releases>
                </repository>
            </repositories>
        </profile>
        <profile>
            <id>repo.jboss-qa-releases</id>
            <activation>
                <activeByDefault>false</activeByDefault>
                <property>
                    <name>repo.jboss-qa-releases</name>
                </property>
            </activation>
            <repositories>
                <repository>
                    <id>jboss-qa-releases</id>
                    <name>JBoss QA Releases</name>
                    <url>${NGINX_ROUTE}/</url>
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
                    <id>jboss-qa-releases</id>
                    <name>JBoss QA Releases</name>
                    <url>${NGINX_ROUTE}/</url>
                </pluginRepository>
            </pluginRepositories>
        </profile>

        <profile>
            <id>repo.fuse-qe-nexus</id>
            <activation>
                <activeByDefault>false</activeByDefault>
                <property>
                    <name>repo.fuse-qe-nexus</name>
                </property>
            </activation>
            <repositories>
                <repository>
                    <id>fuse-qe-nexus</id>
                    <name>FuseQE Nexus Repo (fuse-all)</name>
                    <url>${NGINX_ROUTE}</url>
                    <layout>default</layout>
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
                    <id>fuse-qe-nexus</id>
                    <name>FuseQE Nexus Repo (fuse-all)</name>
                    <url>${NGINX_ROUTE}</url>
                </pluginRepository>
            </pluginRepositories>
        </profile>

        <profile>
            <id>repo.maven-central</id>
            <activation>
                <activeByDefault>false</activeByDefault>
                <property>
                    <name>repo.maven-central</name>
                </property>
            </activation>
            <repositories>
                <repository>
                    <id>maven-central</id>
                    <name>Maven Central</name>
                    <url>https://repo.maven.apache.org/maven2</url>
                    <snapshots>
                        <enabled>false</enabled>
                        <updatePolicy>never</updatePolicy>
                        <checksumPolicy>fail</checksumPolicy>
                    </snapshots>
                    <releases>
                        <enabled>true</enabled>
                        <updatePolicy>never</updatePolicy>
                        <checksumPolicy>fail</checksumPolicy>
                    </releases>
                </repository>
            </repositories>
            <pluginRepositories>
                <pluginRepository>
                    <id>maven-central</id>
                    <name>Maven Central</name>
                    <url>https://repo.maven.apache.org/maven2</url>
                </pluginRepository>
            </pluginRepositories>
        </profile>

        <!-- @See https://docs.engineering.redhat.com/pages/viewpage.action?pageId=124099741 -->
        <profile>
            <id>repo.rh-indy-temporary</id>
            <activation>
                <activeByDefault>false</activeByDefault>
                <property>
                    <name>repo.rh-indy-temporary</name>
                </property>
            </activation>
            <repositories>
                <repository>
                    <id>rh-indy-temporary</id>
                    <name>RH Indy Temporary</name>
                    <url>https://indy.psi.redhat.com/api/content/maven/hosted/temporary-builds/</url>
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
                    <id>rh-indy-temporary</id>
                    <name>RH Indy Temporary</name>
                    <url>https://indy.psi.redhat.com/api/content/maven/hosted/temporary-builds/</url>
                </pluginRepository>
            </pluginRepositories>
        </profile>

        <!-- @See https://docs.engineering.redhat.com/pages/viewpage.action?pageId=124099741 -->
        <profile>
            <id>repo.rh-indy</id>
            <activation>
                <activeByDefault>false</activeByDefault>
                <property>
                    <name>repo.rh-indy</name>
                </property>
            </activation>
            <repositories>
                <repository>
                    <id>rh-indy</id>
                    <name>RH Indy</name>
                    <url>https://indy.psi.redhat.com/api/content/maven/group/builds-untested+shared-imports/</url>
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
                    <id>rh-indy</id>
                    <name>RH Indy</name>
                    <url>https://indy.psi.redhat.com/api/content/maven/group/builds-untested+shared-imports/</url>
                </pluginRepository>
            </pluginRepositories>
        </profile>

        <profile>
            <id>repo.rh-maven-central-proxy</id>
            <activation>
                <activeByDefault>false</activeByDefault>
                <property>
                    <name>repo.rh-maven-central-proxy</name>
                </property>
            </activation>
            <repositories>
                <repository>
                    <id>rh-maven-central-proxy</id>
                    <name>RH Maven Central repo proxy</name>
                    <url>https://repo.maven.apache.org/maven2/</url>
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
                    <id>rh-maven-central-proxy</id>
                    <name>RH Maven Central repo proxy</name>
                    <url>https://repo.maven.apache.org/maven2/</url>
                </pluginRepository>
            </pluginRepositories>
        </profile>

        <profile>
            <id>repo.redhat-ea</id>
            <activation>
                <activeByDefault>false</activeByDefault>
                <property>
                    <name>repo.redhat-ea</name>
                </property>
            </activation>
            <repositories>
                <repository>
                    <id>redhat-ea</id>
                    <name>RH EA (Early Access) Repo</name>
                    <url>https://maven.repository.redhat.com/earlyaccess/all</url>
                    <layout>default</layout>
                    <snapshots>
                        <enabled>false</enabled>
                        <updatePolicy>never</updatePolicy>
                    </snapshots>
                </repository>
            </repositories>
            <pluginRepositories>
                <pluginRepository>
                    <id>redhat-ea</id>
                    <name>RH EA (Early Access) Repo</name>
                    <url>https://maven.repository.redhat.com/earlyaccess/all</url>
                    <layout>default</layout>
                </pluginRepository>
            </pluginRepositories>
        </profile>

        <profile>
            <id>repo.redhat-ga</id>
            <activation>
                <activeByDefault>false</activeByDefault>
                <property>
                    <name>repo.redhat-ga</name>
                </property>
            </activation>
            <repositories>
                <repository>
                    <id>redhat-ga</id>
                    <name>RH GA (General Availability) Repo</name>
                    <url>https://maven.repository.redhat.com/ga</url>
                    <layout>default</layout>
                    <snapshots>
                        <enabled>true</enabled>
                        <updatePolicy>never</updatePolicy>
                    </snapshots>
                </repository>
            </repositories>
            <pluginRepositories>
                <pluginRepository>
                    <id>redhat-ga</id>
                    <name>RH GA (General Availability) Repo</name>
                    <url>https://maven.repository.redhat.com/ga/</url>
                    <layout>default</layout>
                </pluginRepository>
            </pluginRepositories>
        </profile>

        <profile>
            <id>repo.atlassian-public</id>
            <activation>
                <activeByDefault>false</activeByDefault>
                <property>
                    <name>repo.atlassian-public</name>
                </property>
            </activation>
            <repositories>
                <repository>
                    <id>atlassian-public</id>
                    <name>Atlassian Public</name>
                    <url>https://packages.atlassian.com/maven-external/</url>
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
                    <id>atlassian-public</id>
                    <name>Atlassian Public</name>
                    <url>https://packages.atlassian.com/maven-external/</url>
                </pluginRepository>
            </pluginRepositories>
        </profile>

        <profile>
            <id>repo.offline</id>
            <activation>
                <activeByDefault>false</activeByDefault>
                <property>
                    <name>repo.offline</name>
                </property>
            </activation>
            <repositories>
                <repository>
                    <id>offline</id>
                    <name>Local MRRC</name>
                    <url>file:.mrrc/</url>
                    <layout>default</layout>
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
                    <id>offline</id>
                    <name>Local MRRC</name>
                    <url>file:.mrrc/</url>
                </pluginRepository>
            </pluginRepositories>
        </profile>
    </profiles>
    <activeProfiles/>
</settings>
EOF

  oc create configmap mvn-settings -n "${1}" --from-file=/tmp/settings.xml
}

function create_csb_volumes()
{
  oc create -f - <<EOF
  kind: PersistentVolume
  apiVersion: v1
  metadata:
    name: persistent-csb-1
    labels:
      type: local
      application: tnb
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
  name: persistent-tnb-tests
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 19Gi
  selector:
    matchLabels:
      application: tnb
  storageClassName: manual
  volumeMode: Filesystem
EOF
}

function create_nginx() {
  NGINX_DOMAIN="nginx.${CONSOLE_URL#"https://console-openshift-console."}"
  NGINX_HOST=${NGINX_DOMAIN//".org/"/.org}

  oc import-image "${1}"/nginx:latest --from=quay.io/packit/nginx-unprivileged --confirm -n "${1}"
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

        #access_log  /var/log/nginx/host.access.log  main;

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
    application: tnb
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
        application: tnb
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
        - name: tnb-volume
          persistentVolumeClaim:
            claimName: persistent-tnb-tests
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
            - name: tnb-volume
              mountPath: /deployments/.m2/
              subPath: maven-repo
            - name: tnb-volume
              mountPath: /tmp/failsafe-reports/
              subPath: failsafe-reports
            - name: tnb-volume
              mountPath: /tmp/surefire-root/
              subPath: surefire-root
            - name: tnb-volume
              mountPath: /tmp/log/
              subPath: log
EOF

  oc create -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nginx
  labels:
    application: tnb
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

  oc expose svc/nginx --hostname="${NGINX_HOST}"

  NGINX_ROUTE=http://"${NGINX_HOST}"

  cat << EOF > /tmp/test.properties
openshift.namespace=tnb-tests
openshift.namespace.delete=false
test.maven.repository=https://maven.repository.redhat.com/ga/
dballocator.url=http://dballocator.mw.lab.eng.bos.redhat.com:8080
dballocator.requestee=software.tnb.db.dballocator.service
dballocator.expire=6
dballocator.erase=true
tnb.user=tnb-tests
camel.springboot.examples.repo=https://github.com/jboss-fuse/camel-spring-boot-examples
camel.springboot.examples.branch=camel-spring-boot-examples-${CSB_RELEASE}.${CSB_PATCH}
EOF

oc delete configmap test-properties -n "${1}" || true
oc create configmap test-properties -n "${1}" --from-file=/tmp/test.properties

}

function create_dc_and_tnb_framework_pod()
{
  oc create -f - <<EOF
kind: Deployment
apiVersion: apps/v1
metadata:
  name: tnb
  namespace: csb-interop
  annotations:
    image.openshift.io/triggers: '[{"from":{"kind":"ImageStreamTag","name":"tnb:latest"},"fieldPath":"spec.template.spec.containers[?(@.name==\"tnb\")].image"}]'
  labels:
    application: tnb
spec:
  strategy:
    type: Recreate
  triggers:
    - type: ImageChange
      imageChangeParams:
        automatic: true
        containerNames:
          - tnb
        from:
          kind: ImageStreamTag
          name: tnb:latest
    - type: ConfigChange
  replicas: 1
  selector:
    matchLabels:
      deployment: tnb
  template:
    metadata:
      name: tnb
      labels:
        deployment: tnb
        application: tnb
    spec:
      securityContext:
        runAsUser: 0
      terminationGracePeriodSeconds: 60
      volumes:
        - name: mvn-settings
          configMap:
            name: mvn-settings
            items:
            - key: settings.xml
              path: custom.settings.xml
        - name: tnb-volume
          persistentVolumeClaim:
            claimName: persistent-tnb-tests
      containers:
        - name: tnb
          image: tnb:latest
          ports:
            - containerPort: 22
              protocol: TCP
            - containerPort: 80
              protocol: TCP
            - containerPort: 443
              protocol: TCP
          env:
          - name: MVN_ARGS
            value: -Drepo.jboss-qa-releases -Drepo.redhat-ga
          - name: MVN_SETTINGS_PATH
            value: /tmp/custom.settings.xml
          - name: MVN_PROFILES
            value: dballocator
          securityContext:
            privileged: true
          volumeMounts:
            - name: mvn-settings
              mountPath: /tmp/
            - name: tnb-volume
              mountPath: /deployments/.m2/
              subPath: maven-repo
EOF

  sleep 60

  runningPod=true
  while $runningPod; do
    tnbPod=$(oc get pods -n csb-interop -l deployment=tnb --no-headers=true | awk '{print $1}')
    echo "Compiling on $tnbPod"
    sleep 60
    podlog=$(while read line; do echo "$line"; done <<< "$(oc logs --tail=50 "$tnbPod" -n csb-interop)")
    if [[ "$podlog" == *"BUILD SUCCESS"* ]]; then
      runningPod=false
    elif [[ "$podlog" == *"BUILD FAILURE"* ]]; then
      echo "Failure during the TNB build on $tnbPod, deploy/tnb rolling out, copying artifact first"
      oc exec $tnbPod -n csb-interop -- /bin/bash -c 'cp -rf /artifacts-tnb/* /deployments/.m2/repository' || true
      echo "Artifacts re-sync, wait 10 seconds ..."
      sleep 10
      restartPodAfterFailure
      sleep 60
      tnbPod=$(oc get pods -n csb-interop -l deployment=tnb --no-headers=true | awk '{print $1}')
    fi
    echo "Check if TNB is still running: $runningPod"
  done
  echo "Build completed"
  sleep 20
}

function restartPodAfterFailure() {
  echo "NGINX Server rollout ..."
  oc rollout restart deploy/nginx-server -n csb-interop || true
  oc wait pods -n csb-interop -l deployment=nginx --for jsonpath="{status.phase}"=Running --timeout=120s
  sleep 30
  echo "NGINX Route deletion ..."
  NGINX_ROUTE=$(oc get routes nginx -n csb-interop --no-headers=true | awk '{print $2}')
  oc delete route nginx -n csb-interop
  oc expose svc/nginx --hostname=${NGINX_ROUTE}
  echo "NGINX Route recreated."
  echo "TNB pod rollout"
  oc rollout restart deploy/tnb -n csb-interop
  oc wait pods -n csb-interop -l deployment=tnb --for jsonpath="{status.phase}"=Running --timeout=120s
  sleep 30
  echo "TNB pod restarted."
}

function copy_deploy_pod_logs() {
  TNB_POD=$(oc get pods -n csb-interop -l deployment=tnb --no-headers=true | awk '{print $1}')
  echo "get logs from pod ${TNB_POD}"
  mkdir -p "${ARTIFACT_DIR}"/tnb
  oc logs --tail=5000 "$TNB_POD" -n csb-interop > "${ARTIFACT_DIR}"/tnb/deploy-and-compile.log
}

echo "Create project"
create_csb_project_and_policies csb-interop

echo "Create persistent volumes"
create_csb_volumes

echo "Create configmaps"
create_csb_configmaps csb-interop

echo "Create nginx server"
create_nginx csb-interop

echo "Create TNB software image stream"
oc import-image tnb:latest --from=quay.io/rh_integration/tnb:latest -n csb-interop --confirm

echo "Create tnb-tests image stream"
oc import-image tnb-tests:latest --from=quay.io/rh_integration/tnb-tests:latest -n csb-interop --confirm

echo "Compile TNB project through Pod creation"
create_dc_and_tnb_framework_pod

echo "Copy TNB Pod logs"
copy_deploy_pod_logs
