#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Create AWS EC2 instance for redis, S3 Storage Bucket, and AWS RDS Postgreql with default 16
QUAY_AWS_S3_BUCKET="quayoperatorcis3$RANDOM"
QUAY_SUBNET_GROUP="quayoperatorcisubnetgroup$RANDOM"
QUAY_SECURITY_GROUP="quayoperatorcisecuritygroup$RANDOM"
QUAY_OPERATOR_KEY="quayoperatorkey$RANDOM"
QUAY_EC2_INSTANCE="quayoperatorciints$RANDOM"

QUAY_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-aws-secret/access_key)
QUAY_AWS_SECRET_KEY=$(cat /var/run/quay-qe-aws-secret/secret_key)
QUAY_AWS_RDS_POSTGRESQL_DBNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/dbname)
QUAY_AWS_RDS_POSTGRESQL_USERNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/username)
QUAY_AWS_RDS_POSTGRESQL_PASSWORD=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/password)

QUAY_AWS_RDS_POSTGRESQL_VERSION="$POSTGRESQL_VERSION"
QUAY_CLAIR_VERSION="$CLAIR_VERSION"
QUAY_UNMANAGED_AWS_TERRAFORM_PACKAGE="QUAY_UNMANAGED_AWS_TERRAFORM.tgz"

#Create new directory for terraform resources
mkdir -p terraform_quay_aws_unmanaged && cd terraform_quay_aws_unmanaged && touch quaybuilder quaybuilder.pub
cp /var/run/quay-qe-omr-secret/quaybuilder quaybuilder && cp /var/run/quay-qe-omr-secret/quaybuilder.pub quaybuilder.pub
chmod 600 ./quaybuilder && chmod 600 ./quaybuilder.pub && echo "" >> quaybuilder

cat >>variables.tf <<EOF
variable "region" {
  default = "us-east-2"
}
variable "quay_subnet_group" {
  default = "$QUAY_SUBNET_GROUP"
}
variable "quay_security_group" {
  default = "$QUAY_SECURITY_GROUP"
}
variable "aws_bucket" {
  default = "$QUAY_AWS_S3_BUCKET"
}
variable "quay_operator_key" {
  default = "$QUAY_OPERATOR_KEY"
}
variable "quay_ec2_instance" {
  default = "$QUAY_EC2_INSTANCE"
}
EOF

cat >>create_aws_redis_s3_postgresql.tf <<EOF

## EC2 instance for redis server ##
provider "aws" {
  region = "us-east-2"
  access_key = "${QUAY_AWS_ACCESS_KEY}"
  secret_key = "${QUAY_AWS_SECRET_KEY}"
}
resource "aws_vpc" "quayoperatorci" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"
  enable_dns_support = true
  enable_dns_hostnames = true

  tags = {
    Name = "quayoperatorcitest$RANDOM"
  }
}
resource "aws_internet_gateway" "quayoperatorigw" {
  vpc_id = aws_vpc.quayoperatorci.id
}
resource "aws_route" "route-public" {
  route_table_id         = aws_vpc.quayoperatorci.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.quayoperatorigw.id
}
resource "aws_subnet" "quayoperatorci" {
  vpc_id            = aws_vpc.quayoperatorci.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-2b"
}

resource "aws_key_pair" "quayoperatorci" {
  key_name   = var.quay_operator_key
  public_key = file("./quaybuilder.pub")
}

resource "aws_security_group" "quayoperatorsecg" {
  name        = var.quay_security_group
  description = "Allow all inbound traffic"
  vpc_id      = aws_vpc.quayoperatorci.id
  ingress {
    description = "traffic into quayoperator VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "quayoperatorci" {
  key_name      = aws_key_pair.quayoperatorci.key_name
  ami           = "ami-0b2e47f3b2e23d235"
  instance_type = "m4.xlarge"

  associate_public_ip_address = true
  vpc_security_group_ids = [aws_security_group.quayoperatorsecg.id]
  subnet_id = aws_subnet.quayoperatorci.id
  
  ebs_block_device {
    device_name = "/dev/sda1"
    volume_size = 200
  }

#Launch redis instance with docker container
  provisioner "remote-exec" {
    inline = [
      "sudo yum install podman -y",
      "mkdir -p ~/redis-quay",
      "sudo podman run -d  --name redis -p 6379:6379 -e REDIS_PASSWORD=$QUAY_AWS_RDS_POSTGRESQL_PASSWORD -v ~/redis-quay:/var/lib/redis/data:Z quay.io/clair-load-test/redis:6.2.7"
    ]
  }

  connection {
    type        = "ssh"
    host        = self.public_ip
    user        = "ec2-user"
    private_key = file("./quaybuilder")
  }
  tags = {
    Name = var.quay_ec2_instance
  }
}

output "instance_public_ip" {
  value = aws_instance.quayoperatorci.public_ip
}


## Postgres DB Instance ##
resource "aws_subnet" "quayoperatorci2" {
  vpc_id            = aws_vpc.quayoperatorci.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-2c"
}
resource "aws_db_subnet_group" "quayoperatorci" {
  name       = var.quay_subnet_group
  subnet_ids = [aws_subnet.quayoperatorci.id,aws_subnet.quayoperatorci2.id]
  tags = {
    Name = "Quay Operator subnet group"
  }
}
resource "aws_db_instance" "quaydb" {
  allocated_storage    = 30
  storage_type         = "gp2"
  engine               = "postgres"
  engine_version       = "${QUAY_AWS_RDS_POSTGRESQL_VERSION}"
  instance_class       = "db.m5.large"
  db_name              = "${QUAY_AWS_RDS_POSTGRESQL_DBNAME}"
  username             = "${QUAY_AWS_RDS_POSTGRESQL_USERNAME}"
  password             = "${QUAY_AWS_RDS_POSTGRESQL_PASSWORD}"
  publicly_accessible  = true
  skip_final_snapshot  = true
  db_subnet_group_name = aws_db_subnet_group.quayoperatorci.id
  vpc_security_group_ids = [aws_security_group.quayoperatorsecg.id]
  identifier = "quay-operator-ci-test$RANDOM"
}

output "quaydb_address" {
    value = aws_db_instance.quaydb.address
}
output "quaydb_endpint" {
    value = aws_db_instance.quaydb.endpoint
}
output "quaydb_name" {
    value = aws_db_instance.quaydb.db_name
}
output "quaydb_username" {
    value = aws_db_instance.quaydb.username
}

## S3 Bucket ##
resource "aws_s3_bucket" "quayaws" {
  bucket = var.aws_bucket
  force_destroy = true
}
resource "aws_s3_bucket_ownership_controls" "quayaws" {
  bucket = aws_s3_bucket.quayaws.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}
resource "aws_s3_bucket_acl" "quayaws_bucket_acl" {
  depends_on = [aws_s3_bucket_ownership_controls.quayaws]
  bucket = aws_s3_bucket.quayaws.id
  acl    = "private"
}
EOF

terraform --version
terraform init 
terraform apply -auto-approve 

QUAY_AWS_RDS_POSTGRESQL_ADDRESS=$(terraform output quaydb_address | tr -d '""' | tr -d '\n')
QUAY_REDIS_IP_ADDRESS=$(terraform output instance_public_ip | tr -d '""' | tr -d '\n')

#Save for next step
echo "${QUAY_AWS_S3_BUCKET}" >${SHARED_DIR}/QUAY_AWS_S3_BUCKET
echo "${QUAY_REDIS_IP_ADDRESS}" >${SHARED_DIR}/QUAY_REDIS_IP_ADDRESS
echo "${QUAY_AWS_RDS_POSTGRESQL_ADDRESS}" >${SHARED_DIR}/QUAY_AWS_RDS_POSTGRESQL_ADDRESS

#Share the Terraform Var and Terraform Directory
tar -cvzf $QUAY_UNMANAGED_AWS_TERRAFORM_PACKAGE --exclude=".terraform" *
echo "Copy terraform tf files"
cp $QUAY_UNMANAGED_AWS_TERRAFORM_PACKAGE ${SHARED_DIR}

cd .. && mkdir -p terraform_install_extension && cd terraform_install_extension
cat >>variables.tf <<EOF
variable "quay_db_host" {
}
EOF

cat >>install_extension.tf <<EOF
terraform {
  required_providers {
    postgresql = {
      source = "cyrilgdn/postgresql"
      version = "1.22.0"
    }
  }
}
provider "postgresql" {
  host            = var.quay_db_host
  username        = "${QUAY_AWS_RDS_POSTGRESQL_USERNAME}"
  password        = "${QUAY_AWS_RDS_POSTGRESQL_PASSWORD}"
  expected_version = "${QUAY_AWS_RDS_POSTGRESQL_VERSION}"
  sslmode         = "require"
  connect_timeout = 15
}

## Provision db with name "clair" for clairpostgres 
resource "postgresql_database" "clairdb" {
  name              = "clair"
  connection_limit  = -1
  allow_connections = true
}
resource "postgresql_extension" "pg_trgm" {
  name     = "pg_trgm"
  database = "${QUAY_AWS_RDS_POSTGRESQL_DBNAME}"
}
resource "postgresql_extension" "uuid-ossp" {
  name     = "uuid-ossp"
  database = "clair"
  depends_on=[postgresql_database.clairdb]
}
EOF

export TF_VAR_quay_db_host="${QUAY_AWS_RDS_POSTGRESQL_ADDRESS}"
terraform init 
terraform apply -auto-approve 

## Provisiong Clair instance, default version 4.7.4 ##
clair_app_namespace="clair-quay-operatortest"
clair_tls_secret="clair-config-tls-secret"
clair_setup_yaml="clair-setup-quay-operatortest.yaml"

cat >>$clair_setup_yaml <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: clair-cluster-trusted-ca
  namespace: ${clair_app_namespace}
  labels:
      config.openshift.io/inject-trusted-cabundle: 'true'
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: clair-serviceaccount
  namespace: ${clair_app_namespace}
rules:
- apiGroups:
  - ""
  resources:
  - secrets
  verbs:
  - get
  - put
  - patch
  - update
- apiGroups:
  - ""
  resources:
  - namespaces
  verbs:
  - get
- apiGroups:
  - extensions
  - apps
  resources:
  - deployments
  verbs:
  - get
  - list
  - patch
  - update
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: clair-secret-writer
  namespace: ${clair_app_namespace}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: clair-serviceaccount
subjects:
- kind: ServiceAccount
  name: default
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-clair-storage-operator
  namespace: ${clair_app_namespace}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: postgres-clair
  name: postgres-clair
  namespace: ${clair_app_namespace}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres-clair
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: postgres-clair
    spec:
      containers:
      - env:
        - name: POSTGRESQL_USER
          value: ${QUAY_AWS_RDS_POSTGRESQL_USERNAME}
        - name: POSTGRESQL_DATABASE
          value: clair
        - name: POSTGRESQL_PASSWORD
          value: ${QUAY_AWS_RDS_POSTGRESQL_PASSWORD}
        - name: POSTGRESQL_ADMIN_PASSWORD
          value: ${QUAY_AWS_RDS_POSTGRESQL_PASSWORD}
        - name: POSTGRESQL_SHARED_BUFFERS
          value: 256MB
        - name: POSTGRESQL_MAX_CONNECTIONS
          value: "2000"
        image: registry.redhat.io/rhel8/postgresql-13@sha256:eceab3d3b02f7d24054c410054b2f125eb4ec4ac9cca9d3f21702416d55a6c5c
        imagePullPolicy: IfNotPresent
        name: postgres-clair
        resources:
          requests:
            cpu: 500m
            memory: 2Gi
        ports:
        - containerPort: 5432
          protocol: TCP
        volumeMounts:
        - mountPath: /var/lib/pgsql/data
          name: postgredb
      volumes:
      - name: postgredb
        persistentVolumeClaim:
          claimName: postgres-clair-storage-operator
      terminationGracePeriodSeconds: 180
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app: postgres-clair
  name: postgres-clair
  namespace: ${clair_app_namespace}
spec:
  ports:
  - name: postgres
    port: 5432
    protocol: TCP
    targetPort: 5432
    nodePort: 30432
  selector:
    app: postgres-clair
  type: NodePort
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: clair-configmap
  namespace: ${clair_app_namespace}
data:
  config.yaml: |
    introspection_addr: ""
    http_listen_addr: :8080
    log_level: debug-color
    updaters:
      config:
          rhel:
              ignore_unpatched: false
    indexer:
      connstring: host=postgres-clair port=5432 dbname=clair user=${QUAY_AWS_RDS_POSTGRESQL_USERNAME} password=${QUAY_AWS_RDS_POSTGRESQL_PASSWORD} sslmode=disable
      scanlock_retry: 10
      layer_scan_concurrency: 10
      migrations: true
      scanner:
            package: {}
            dist: {}
            repo: {}
      airgap: false
      index_report_request_concurrency: -1
    matcher:
      connstring: host=postgres-clair port=5432 dbname=clair user=${QUAY_AWS_RDS_POSTGRESQL_USERNAME} password=${QUAY_AWS_RDS_POSTGRESQL_PASSWORD} sslmode=disable
      max_conn_pool: 100
      indexer_addr: "http://clair-indexer"
      migrations: true
      period: 6h
      disable_updaters: false
    matchers:
      names: null
    notifier:
      indexer_addr: "http://clair-indexer"
      matcher_addr: "http://clair-matcher"
      connstring: host=postgres-clair port=5432 dbname=clair user=${QUAY_AWS_RDS_POSTGRESQL_USERNAME} password=${QUAY_AWS_RDS_POSTGRESQL_PASSWORD} sslmode=disable
      migrations: true
      delivery_interval: 1m
      poll_interval: 6h
      amqp: null
      stomp: null
    auth:
      psk:
        key: Y2xhaXJzaGFyZWRwYXNzd29yZA==
        iss:
            - quay
    metrics:
      name: "prometheus"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: clair-deployment-quay
  namespace: ${clair_app_namespace}
spec:
  selector:
    matchLabels:
      app: clair
  replicas: 2
  template:
    metadata:
      labels:
        app: clair
    spec:
      volumes:
        - name: clair-config
          configMap:
            name: clair-configmap
        - name: cluster-trusted-ca
          configMap:
            name: clair-cluster-trusted-ca
            items:
              - key: ca-bundle.crt
                path: tls-ca-bundle.pem
            defaultMode: 420
        - name: certificates
          projected:
            sources:
              - secret:
                  name: $clair_tls_secret
              - configMap:
                  name: openshift-service-ca.crt
              - configMap:
                  name: clair-cluster-trusted-ca	  
            defaultMode: 420
      containers:
        - name: clair
          image: quay.io/projectquay/clair:$QUAY_CLAIR_VERSION
          imagePullPolicy: IfNotPresent
          ports:
          - containerPort: 8080
            name: clair-http
            protocol: TCP
          - containerPort: 8089
            name: clair-intro
            protocol: TCP
          startupProbe:
            tcpSocket:
              port: clair-intro
            periodSeconds: 10
            failureThreshold: 300
          readinessProbe:
            tcpSocket:
              port: 8080
          livelinessProbe:
            httpGet:
              port: clair-intro
              path: /healthz
          resources:
            limits:
              cpu: "4"
              memory: 16Gi
            requests:
              cpu: "2"
              memory: 2Gi
          env:
            - name: CLAIR_MODE
              value: combo
            - name: CLAIR_CONF
              value: /clair/config.yaml
          volumeMounts:
            - name: clair-config
              mountPath: /clair/config.yaml
              subPath: config.yaml
              readOnly: true
            - name: cluster-trusted-ca
              mountPath: /etc/pki/ca-trust/extracted/pem
              readOnly: true  
            - name: certificates
              mountPath: /var/run/certs
---
apiVersion: v1
kind: Service
metadata:
  name: clair-service-quay
  namespace: ${clair_app_namespace}
spec:
  selector:
    app: clair
  ports:
    - name: clair-http
      port: 80
      protocol: TCP
      targetPort: 8080
    - name: clair-introspection
      port: 8089
      protocol: TCP
      targetPort: 8089
  type: ClusterIP
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: clair-quay-operatortest
  namespace: ${clair_app_namespace}
spec:
  to:
    kind: Service
    name: clair-service-quay
  port:
    targetPort: clair-http
  wildcardPolicy: None
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: clair-service-monitor
  namespace: ${clair_app_namespace}
  labels:
    app: clair
spec:
  selector:
    matchLabels:
      app: clair
  endpoints:
  - port: clair-introspection
    path: /metrics
    interval: 30s
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: clair-deployment-quay
  namespace: ${clair_app_namespace}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: clair-deployment-quay
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 90
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 90
EOF

oc new-project ${clair_app_namespace} 

#extract tls.crt from openshift-ingress and create a secret with it
oc extract secrets/router-certs-default -n openshift-ingress --confirm && oc create secret generic $clair_tls_secret --from-file=ocp-cluster-wildcard.cert=tls.crt -n ${clair_app_namespace}
oc apply -f $clair_setup_yaml -n ${clair_app_namespace} || true
sleep 15

clair_route_name="$(oc get route -n ${clair_app_namespace} -o jsonpath='{.items[0].spec.host}')"
echo "$clair_route_name"

#Save for next step and recycle
echo "${clair_route_name}" >${SHARED_DIR}/CLAIR_ROUTE_NAME
cp $clair_setup_yaml ${SHARED_DIR} || true

for _ in {1..60}; do
  if [[ "$(oc -n ${clair_app_namespace} get deployment clair-deployment-quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)" == "True" ]]; then
    echo "Clair is in ready status" >&2
    exit 0
  fi
  sleep 15
done


