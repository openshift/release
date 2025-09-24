#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

###
# Ceph storage requires large resources: 30 CPUs and 72 GiB of RAM
# Steps:
# 1, Deploy Odf operator first, 
# 2, next create a StorageCluster,
# 3, then deploy three Ceph RGW: CephObjectStore,s3-rgw, StorageClass
# 4, finally create s3 bucket with ObjectBucketClaim
# See: https://issues.redhat.com/browse/OCPQE-14826 https://issues.redhat.com/browse/OCPQE-30200
###

# ODF Operator has Deployed to OCP namespace 'openshift-storage'

# Configuration
STORAGE_CLASS="ocs-storagecluster-ceph-rgw"
BUCKET_PREFIX="${BUCKET_PREFIX:-quay}"
OBC_NAME="${BUCKET_PREFIX}-bucket"
NAMESPACE="${NAMESPACE:-openshift-storage}"
REGION_NAME="${REGION_NAME:-us-east-1}"
TIMEOUT="${TIMEOUT:-300}"

check_prerequisites() {

	if ! oc get deployment odf-operator-controller-manager -n openshift-storage &>/dev/null; then
		echo "ERROR: odf-operator-controller-manager deployment not found"
		exit 1
	fi

	echo "Prerequisites check passed"
}


# deploy_odf_operator() {

# 	cat <<EOF | oc apply -f -
# apiVersion: v1
# kind: Namespace
# metadata:
#   name: openshift-storage
# EOF

# 	OPERATORGROUP=$(oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup -o jsonpath="{.items[*].metadata.name}" || true)
# 	if [[ -n "$OPERATORGROUP" ]]; then
# 		echo "OperatorGroup \"$OPERATORGROUP\" exists: modifying it"
# 		OG_OPERATION=apply
# 		OG_NAMESTANZA="name: $OPERATORGROUP"
# 	else
# 		echo "OperatorGroup does not exist: creating it"
# 		OG_OPERATION=create
# 		OG_NAMESTANZA="generateName: oo-"
# 	fi

# 	OPERATORGROUP=$(
# 		oc $OG_OPERATION -f - -o jsonpath='{.metadata.name}' <<EOF
# apiVersion: operators.coreos.com/v1
# kind: OperatorGroup
# metadata:
#   $OG_NAMESTANZA
#   namespace: $OO_INSTALL_NAMESPACE
# spec:
#   targetNamespaces: [$OO_INSTALL_NAMESPACE]
# EOF
# 	)

# 	SUB=$(
# 		cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
# apiVersion: operators.coreos.com/v1alpha1
# kind: Subscription
# metadata:
#   name: $ODF_SUBSCRIPTION_NAME
#   namespace: $OO_INSTALL_NAMESPACE
# spec:
#   channel: $ODF_OPERATOR_CHANNEL
#   installPlanApproval: Automatic
#   name: $ODF_SUBSCRIPTION_NAME
#   source: redhat-operators
#   sourceNamespace: openshift-marketplace
# EOF
# 	)

# 	for i in {1..60}; do
# 		CSV=$(oc -n "$OO_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
# 		if [[ -n "$CSV" ]]; then
# 			if [[ "$(oc -n "$OO_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
# 				echo "ODF ClusterServiceVersion \"$CSV\" ready"
# 				break
# 			fi
# 		fi
# 		echo "wait $((i * 10))s"
# 		sleep 10
# 	done
# 	echo "ODF Operator is deployed successfully"

# 	# Wait for odf operator pod startup
# 	for i in {1..60}; do
# 		PStatus=$(oc -n "$OO_INSTALL_NAMESPACE" get pod -l name=ocs-operator -o jsonpath='{..status.conditions[?(@.type=="Ready")].status}' || true)
# 		if [[ "$PStatus" == "True" ]]; then
# 			echo "ODF pod is running \"$PStatus\""
# 			break
# 		fi
# 		podstatus=$(oc -n "$OO_INSTALL_NAMESPACE" get pod)
# 		echo "odf pod status $podstatus"
# 		echo "wait $((i * 10))s"
# 		sleep 10
# 	done
# }

# Deploy ODF StorageSystem
deploy_storage_cluster() {
	oc patch console.operator cluster -n openshift-storage --type json -p '[{"op": "add", "path": "/spec/plugins", "value": ["odf-console"]}]'

	#Default label is: cluster.ocs.openshift.io/openshift-storage=
    #as node may recreate, we use a more general label "node-role.kubernetes.io/worker" for worker, set in cephobjectstore.yaml
	oc label node -l node-role.kubernetes.io/worker -l '!node-role.kubernetes.io/master' cluster.ocs.openshift.io/openshift-storage=''
	
	cat <<EOF | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  arbiter: {}
  encryption:
    kms: {}
  externalStorage: {}
  flexibleScaling: true
  resources:
    mds:
      limits:
        cpu: "3"
        memory: "8Gi"
      requests:
        cpu: "3"
        memory: "8Gi"
  monDataDirHostPath: /var/lib/rook
  managedResources:
    cephBlockPools:
      reconcileStrategy: manage
    cephConfig: {}
    cephFilesystems: {}
    cephObjectStoreUsers: {}
    cephObjectStores: {}
  multiCloudGateway:
    reconcileStrategy: manage
  storageDeviceSets:
  - count: 1
    dataPVCTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: "2Ti"
        storageClassName: gp3-csi
        volumeMode: Block
    name: ocs-deviceset-gp3-csi
    placement: {}
    portable: true
    replica: 3
    resources:
      limits:
        cpu: "2"
        memory: "5Gi"
      requests:
        cpu: "2"
        memory: "5Gi"
# Use below common label for all worker
  nodeTopologies:
    labels:
      node-role.kubernetes.io/worker:
EOF
    sleep 5m
	for i in {1..50}; do
		phase=$(oc get storagecluster -n openshift-storage ocs-storagecluster -o jsonpath='{.status.phase}' || echo "Failure")
		if [[ "$phase" == "Ready" ]]; then
			echo "ODF StorageCluster is Ready"
			break
		fi
		echo "Waiting for StorageCluster to be Ready, current status is ${phase}..."
		sleep 30
	done
	phase=$(oc get storagecluster -n openshift-storage ocs-storagecluster -o jsonpath='{.status.phase}' || echo "Failure")
	if [[ "$phase" != "Ready" ]]; then
		echo "Timed out waiting for StorageCluster to be Ready"
		exit 1
	fi

}

# Ceph Storage’s RADOS Object Gateway deployment
deploy_ceph_rgw() {
	# Creating the CephObjectStore
	cat <<EOF | oc apply -f -
---
apiVersion: ceph.rook.io/v1
kind: CephObjectStore
metadata:
  name: ocs-storagecluster-cephobjectstore
  namespace: openshift-storage
spec:
  dataPool:
    crushRoot: ""
    deviceClass: ""
    erasureCoded:
      algorithm: ""
      codingChunks: 0
      dataChunks: 0
    failureDomain: host
    replicated:
      size: 3
  gateway:
    allNodes: false
    instances: 1
    placement:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: cluster.ocs.openshift.io/openshift-storage
              operator: Exists
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
        - podAffinityTerm:
            labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - rook-ceph-rgw
            topologyKey: kubernetes.io/hostname
          weight: 100
      tolerations:
      - effect: NoSchedule
        key: node.ocs.openshift.io/storage
        operator: Equal
        value: "true"
    port: 80
    resources:
      limits:
        cpu: "2"
        memory: 4Gi
      requests:
        cpu: "1"
        memory: 4Gi
    securePort: 0
    sslCertificateRef: ""
  metadataPool:
    crushRoot: ""
    deviceClass: ""
    erasureCoded:
      algorithm: ""
      codingChunks: 0
      dataChunks: 0
    failureDomain: host
    replicated:
      size: 3
EOF

	# Service and Route
	cat <<EOF | oc apply -f -
---
kind: Route
apiVersion: route.openshift.io/v1
metadata:
  name: s3-rgw
  namespace: openshift-storage
  labels:
    app: rook-ceph-rgw
    ceph_daemon_id: ocs-storagecluster-cephobjectstore
    ceph_daemon_type: rgw
    rgw: ocs-storagecluster-cephobjectstore
    rook_cluster: openshift-storage
    rook_object_store: ocs-storagecluster-cephobjectstore
spec:
  to:
    kind: Service
    name: rook-ceph-rgw-ocs-storagecluster-cephobjectstore
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Allow
  wildcardPolicy: None
EOF
	# StorageClass
	cat <<EOF | oc apply -f -
---
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: ocs-storagecluster-ceph-rgw
  annotations:
    description: Provides Object Bucket Claims (OBCs) using the RGW
provisioner: openshift-storage.ceph.rook.io/bucket
parameters:
  objectStoreName: ocs-storagecluster-cephobjectstore
  objectStoreNamespace: openshift-storage
  region: us-east-1
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF

	for _ in {1..20}; do
		if oc wait --for=condition=Ready pod -l app=rook-ceph-rgw -n openshift-storage --timeout=30s; then
			echo "rook-ceph-rgw pod is Ready"
			break
		fi
		echo "Waiting for rook-ceph-rgw pods to be Ready..."
	done	

}

# Using the Rook-Ceph toolbox to check on the Ceph backing storage
# deploy_s3_bucket() {
# 	ceph_toolbox_pod_name=$(oc get pod -n openshift-storage -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}')
# 	echo "${ceph_toolbox_pod_name}"
# 	oc exec -n openshift-storage "${ceph_toolbox_pod_name}" -- ceph osd status
# 	oc exec -n openshift-storage "${ceph_toolbox_pod_name}" -- ceph status

# 	oc exec -n openshift-storage "${ceph_toolbox_pod_name}" -- radosgw-admin user create --uid="quay" --display-name="quay user" >quayuser.json
# 	cat quayuser.json
# 	echo "Ceph RGW Storage is deployed successfully"

# 	cat quayuser.json | jq '.keys[0].access_key' >ceph_access_key
# 	cat quayuser.json | jq '.keys[0].secret_key' >ceph_secret_key
# 	cat ceph_access_key | tr -d '\\n' >ceph_access_key_new
# 	cat ceph_secret_key | tr -d '\\n' >ceph_secret_key_new

# 	oc get route -n openshift-storage s3-rgw -o json | jq '.spec.host' >ceph_gw_hostname
# 	cat ceph_gw_hostname | tr -d '\\n' >ceph_gw_hostname_new
# 	export AWS_ACCESS_KEY_ID="${env.ceph_access_key}"
# 	export AWS_SECRET_ACCESS_KEY="${env.ceph_secret_key}"

# 	aws s3api create-bucket --bucket quay --no-verify-ssl --region "us-east-1" --endpoint https://"${ceph_gw_hostname}"
# 	aws s3 cp quayuser.json s3://quay --no-verify-ssl --region "us-east-1" --endpoint https://"${ceph_gw_hostname}"

# }


get_rgw_route() {
	echo "Getting RGW route..."
	RGW_ROUTE=$(oc get routes -n openshift-storage -o jsonpath='{.items[?(@.metadata.name=="s3-rgw")].spec.host}' 2>/dev/null || echo "")

	if [[ -z "$RGW_ROUTE" ]]; then
		echo "ERROR: RGW route not found"
		exit 1
	fi

	export RGW_ROUTE
	echo "RGW route: ${RGW_ROUTE}"
	echo "${RGW_ROUTE}" > "${SHARED_DIR}/QUAY_CEPH_S3_HOSTNAME"
}

# ObjectBucketClaim (OBC) method for ODF 4.16+
# ceph version 19.2.1-245.el9cp squid -> Red Hat Ceph Storage 8.x
# ceph version 18.2.1-340.el9cp reef -> Red Hat Ceph Storage 7.x
create_bucket_obc() {
	echo "Creating S3 bucket using ObjectBucketClaim (ODF 4.16+ method) $ODF_OPERATOR_CHANNEL ..."

	if ! oc get crd objectbucketclaims.objectbucket.io &>/dev/null; then
		echo "ERROR: ObjectBucketClaim CRD not found. Falling back to legacy method."
		return 1
	fi

	cat <<EOF | oc apply -f -
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ${OBC_NAME}
  namespace: ${NAMESPACE}
spec:
  bucketName: quay
  storageClassName: ${STORAGE_CLASS}
EOF

	echo "Waiting for ObjectBucketClaim to be bound..."
	local elapsed=0
	local interval=10

	while [ $elapsed -lt "$TIMEOUT" ]; do
		local phase
		phase=$(oc get obc "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

		if [ "$phase" = "Bound" ]; then
			echo "ObjectBucketClaim is bound"
			break
		fi

		echo -n "."
		sleep $interval
		elapsed=$((elapsed + interval))
	done

	if [ $elapsed -ge "$TIMEOUT" ]; then
		echo "ERROR: Timeout waiting for ObjectBucketClaim to be bound"
		return 1
	fi

	BUCKET_NAME=$(oc get obc "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.bucketName}')
	ACCESS_KEY=$(oc get secret "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
	SECRET_KEY=$(oc get secret "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

	if [[ -z "$BUCKET_NAME" ]] || [[ -z "$ACCESS_KEY" ]] || [[ -z "$SECRET_KEY" ]]; then
		echo "ERROR: Failed to extract bucket information from OBC"
		return 1
	fi

	export BUCKET_NAME ACCESS_KEY SECRET_KEY
	echo "OBC bucket created successfully: ${BUCKET_NAME}"
    echo "${ACCESS_KEY}" > "${SHARED_DIR}/QUAY_CEPH_S3_ACCESSKEY"
    echo "${SECRET_KEY}" > "${SHARED_DIR}/QUAY_CEPH_S3_SECRETKEY"

	return 0
}

# Using the Rook-Ceph toolbox to check on the Ceph backing storage

create_bucket_legacy() {
	echo "Creating S3 bucket using AWS CLI method ODF $ODF_OPERATOR_CHANNEL ..."

	local ceph_toolbox_pod
	ceph_toolbox_pod=$(oc get pod -n openshift-storage -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

	if [[ -z "$ceph_toolbox_pod" ]]; then
		echo "ERROR: Ceph toolbox pod not found"
		exit 1
	fi
	echo "${ceph_toolbox_pod}"
	oc exec -n openshift-storage "${ceph_toolbox_pod}" -- ceph osd status
	oc exec -n openshift-storage "${ceph_toolbox_pod}" -- ceph status
    BUCKET_NAME="${BUCKET_PREFIX}"

	echo "Creating RGW user: ${BUCKET_NAME}"
	local rgw_user_output
	rgw_user_output=$(oc exec -n openshift-storage "${ceph_toolbox_pod}" -- radosgw-admin user create \
		--uid="${BUCKET_NAME}" \
		--display-name="${BUCKET_NAME} user")

	ACCESS_KEY=$(echo "$rgw_user_output" | jq -r '.keys[0].access_key')
	SECRET_KEY=$(echo "$rgw_user_output" | jq -r '.keys[0].secret_key')

	if [[ -z "$ACCESS_KEY" ]] || [[ -z "$SECRET_KEY" ]] || [[ "$ACCESS_KEY" == "null" ]] || [[ "$SECRET_KEY" == "null" ]]; then
		echo "ERROR: Failed to extract credentials from RGW user creation"
		exit 1
	fi

	oc exec -n openshift-storage "${ceph_toolbox_pod}" -- radosgw-admin caps add \
		--uid="${BUCKET_NAME}" \
		--caps="buckets=*" >/dev/null

	if command -v aws &>/dev/null; then
		echo "Creating bucket: ${BUCKET_NAME}"
		export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
		export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"

		if aws s3api create-bucket \
			--bucket "${BUCKET_NAME}" \
			--region "${REGION_NAME}" \
			--endpoint-url "https://${RGW_ROUTE}" \
			--no-verify-ssl 2>/dev/null; then
			echo "Bucket created successfully via AWS CLI"
		else
			echo "WARNING: Bucket creation via aws s3api failed, but credentials should still work for auto-creation"
		fi
	fi

	export BUCKET_NAME ACCESS_KEY SECRET_KEY
	echo "AWS s3api bucket setup completed: ${BUCKET_NAME}"

    echo "${ACCESS_KEY}" > "${SHARED_DIR}/QUAY_CEPH_S3_ACCESSKEY"
    echo "${SECRET_KEY}" > "${SHARED_DIR}/QUAY_CEPH_S3_SECRETKEY"
}

create_s3_bucket() {
	echo "Creating S3 bucket (method: auto-detect based on ODF version)..."

	local channel="${ODF_OPERATOR_CHANNEL:-stable-4.19}"
	local odf_version="${channel#stable-}"

	if [[ "$odf_version" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
		local major="${BASH_REMATCH[1]}"
		local minor="${BASH_REMATCH[2]}"

		if [[ $major -gt 4 ]] || [[ $major -eq 4 && $minor -ge 16 ]]; then
			echo "Using ODF ${odf_version} ObjectBucketClaim method"
	        create_bucket_obc
		else
			echo "Using ODF ${odf_version} legacy AWS CLI method"
			oc patch OCSInitialization ocsinit -n openshift-storage --type json --patch '[{ "op": "replace", "path": "/spec/enableCephTools", "value": true }]'
	        oc patch storagecluster ocs-storagecluster -n openshift-storage --type json --patch '[{ "op": "replace", "path": "/spec/enableCephTools", "value": true }]'

			echo "Waiting for ceph-tools pod to be ready..."
			for _ in {1..10}; do
				if oc wait --for=condition=Ready pod -l app=rook-ceph-tools -n openshift-storage --timeout=30s 2>/dev/null; then
					echo "ceph-tools pod is ready"
					break
				fi
				sleep 10
			done

		    create_bucket_legacy
		fi
	else
		echo "Could not parse ODF version ${odf_version} from ${ODF_OPERATOR_CHANNEL}"
	fi
}

verify_bucket_connectivity() {
	echo "Verifying bucket connectivity..."

	local test_url="https://${RGW_ROUTE}/"

	if curl -k -s --max-time 10 "$test_url" >/dev/null 2>&1; then
		echo "RGW endpoint is accessible"
	else
		echo "WARNING: RGW endpoint connectivity test failed"
	fi

	if command -v aws &>/dev/null; then
		export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
		export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"

		if aws s3api head-bucket \
			--bucket "${BUCKET_NAME}" \
			--endpoint-url "https://${RGW_ROUTE}" \
			--no-verify-ssl >/dev/null 2>&1; then
			echo "Bucket access verified"
		else
			echo "WARNING: Bucket access verification failed (may still work with Quay)"
		fi
	fi
}

## Provisioning Ceph Steps, based on ODF has been deployed
	echo "Starting Ceph Storage Provisioning for Quay Tests"
	echo "=================================================="

	# deploy_odf_operator
	check_prerequisites
	deploy_storage_cluster
	deploy_ceph_rgw
	get_rgw_route
	create_s3_bucket
	verify_bucket_connectivity

	echo "Ceph storage provisioning completed successfully!"

