#!/bin/bash

set -ex
set -o pipefail

job_id=$(echo -n $PROW_JOB_ID|cut -c-8)
export job_id
export CLUSTER_NAME="${CLUSTER_NAME_PREFIX}-${job_id}"
CLUSTER_ARCH=s390x
export CLUSTER_ARCH
#export CLUSTER_VERSION="4.19.0"
cat "${AGENT_IBMZ_CREDENTIALS}/abi-pull-secret" | jq -c > "$HOME/pull-secret" 
export PULL_SECRET_FILE="$HOME/pull-secret"

ssh_key_string=$(cat "${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-key")
export ssh_key_string
tmp_ssh_key="/tmp/ssh-private-key"
envsubst <<"EOF" >${tmp_ssh_key}
-----BEGIN OPENSSH PRIVATE KEY-----
${ssh_key_string}
-----END OPENSSH PRIVATE KEY-----
EOF
chmod 0600 ${tmp_ssh_key}

set +x
IC_API_KEY=$(cat "${IC_API_KEY_FILE}")
export IC_API_KEY
set -x


# Run the clone
GIT_SSH_COMMAND="ssh -i $tmp_ssh_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no" \
git clone -b image-name-fix git@github.ibm.com:OpenShift-on-Z/ibmcloud-openshift-provisioning.git

# Apply patch to the cloned repo
git -C ibmcloud-openshift-provisioning apply <<'PATCH'
diff --git a/scripts/2-create-infrastructure.sh b/scripts/2-create-infrastructure.sh
index e0ab984..c946320 100755
--- a/scripts/2-create-infrastructure.sh
+++ b/scripts/2-create-infrastructure.sh
@@ -115,27 +115,50 @@ create_vsi() {
     if ! ibmcloud is vni $VSI_NAME-vni >/dev/null 2>&1; then
         echo -e "\nVirtual Network Interface $VSI_NAME-vni does not exists in the $VPC_NAME vpc, creating now..."
         ibmcloud is vnic --name "$VSI_NAME-vni" --sgs "$SG_NAME" --vpc "$VPC_NAME" --subnet "$SUBNET_NAME"
+        echo "Waiting for the VNI $VSI_NAME-vni to become stable under 1 minute ⏳..."
+        for i in {1..12}; do
+            vni_state=$(ibmcloud is vni $VSI_NAME-vni --output JSON | jq -r '.lifecycle_state')
+            if [ "$vni_state" == "stable" ]; then
+                echo "✅ VNI $VSI_NAME-vni is stable."
+                break
+            fi
+            if [ $i -eq 12 ]; then
+                echo "⚠️  VNI $VSI_NAME-vni did not become stable after 1 minute (last state: $vni_state). Cleaning up to try another zone..."
+                ibmcloud is virtual-network-interface-delete $VSI_NAME-vni --force || true
+                return 1
+            fi
+            echo "🔄 Retry $i/11: Waiting for VNI $VSI_NAME-vni to become stable, sleeping for 5 seconds ⏳..."
+            sleep 5
+        done
     else
         echo -e "\nVirtual Network Interface $VSI_NAME-vni already exists in the $VPC_NAME vpc, Skipping the creation..."
     fi
 
     if ! resource_exists "instance" $VSI_NAME; then
         vol_json=$(jq -n -c --arg volume "$VSI_NAME-volume" '{"name": $volume, "volume": {"name": $volume, "capacity": 250, "profile": {"name": "general-purpose"}}}')
-        ibmcloud is instance-create "$VSI_NAME" "$VPC_NAME" "$ZONE" "$PROFILE" "$SUBNET_NAME" --image "$IMAGE_NAME" --keys "$SSH_KEY_NAME" --pnac-vni "$VSI_NAME-vni" --boot-volume "$vol_json"
-        echo "Waiting for the $VSI_NAME VSI to be ready under 2 minutes ⏳..."
+        echo -e "\nCreating VSI $VSI_NAME in zone $ZONE with profile $PROFILE..."
+        if ! ibmcloud is instance-create "$VSI_NAME" "$VPC_NAME" "$ZONE" "$PROFILE" "$SUBNET_NAME" --image "$IMAGE_NAME" --keys "$SSH_KEY_NAME" --pnac-vni "$VSI_NAME-vni" --boot-volume "$vol_json"; then
+            echo "⚠️  instance-create failed for $VSI_NAME in $ZONE (likely no capacity for $PROFILE). Cleaning up VNI to try another zone..."
+            ibmcloud is virtual-network-interface-delete $VSI_NAME-vni --force || true
+            return 1
+        fi
+        echo "Waiting for the $VSI_NAME VSI to be ready in $ZONE under ~3 minutes ⏳..."
         for i in {1..20}; do
             state=$(ibmcloud is instance $VSI_NAME --output JSON | jq -r '.status')
-            if [ "$state" != "available" ] && [ "$state" != "running" ]; then
-                if [ $i -eq 20 ]; then
-                    echo "❌ Error: VSI $VSI_NAME creation is not successful even after 2 minutes. Exiting now."
-                    exit 1
-                fi
-                echo "🔄 Retry $i/19: Waiting for VSI $VSI_NAME to be in ready state, sleeping for 10 seconds ⏳..."
-                sleep 10
-            else
-                echo "✅ Successfully created the VSI: $VSI_NAME in VPC: $VPC_NAME"
+            if [ "$state" == "available" ] || [ "$state" == "running" ]; then
+                echo "✅ Successfully created the VSI: $VSI_NAME in zone $ZONE"
                 break
             fi
+            if [ "$state" == "failed" ] || [ $i -eq 20 ]; then
+                echo "⚠️  VSI $VSI_NAME is not healthy in $ZONE (state: $state). Cleaning up to try another zone..."
+                ibmcloud is instance-delete $VSI_NAME --force || true
+                for d in {1..18}; do ibmcloud is instance $VSI_NAME >/dev/null 2>&1 || break; sleep 5; done
+                ibmcloud is virtual-network-interface-delete $VSI_NAME-vni --force || true
+                sleep 3
+                return 1
+            fi
+            echo "🔄 Retry $i/19: Waiting for VSI $VSI_NAME to be in ready state, sleeping for 10 seconds ⏳..."
+            sleep 10
         done
     fi
 
@@ -277,29 +300,46 @@ esac
 IMAGE_NAME=$(ibmcloud is images --output JSON | jq -r --arg arch "$IMAGE_ARCH" '.[]|select(.operating_system.family == "Ubuntu Linux" and .operating_system.architecture == $arch and .status == "available")|.name' | tail -n 1)
 IMAGE_NAME="${VSI_IMAGE_NAME:-$IMAGE_NAME}"
 
+# Create a VSI with automatic zone fallback. Tries the requested zone first, then
+# the remaining zones in the order 1 -> 3 -> 2 (zone 2 tried last as it most often
+# lacks capacity for some profiles). create_vsi returns non-zero when a zone has no
+# capacity — having cleaned up its half-created instance/VNI first — so we simply
+# move on to the next zone. Zone and subnet are derived from REGION_ID/CLUSTER_NAME.
+create_vsi_with_fallback() {
+    local name=$1 base_znum=$2 profile=$3 image=$4 keys=$5 sg=$6
+    local order=("$base_znum") znum z
+    for z in 1 3 2; do [ "$z" != "$base_znum" ] && order+=("$z"); done
+    for znum in "${order[@]}"; do
+        if create_vsi "$name" "${REGION_ID}-${znum}" "$profile" "${CLUSTER_NAME}-sn-${znum}" "$image" "$keys" "$sg"; then
+            return 0
+        fi
+        echo "🧹 Zone ${REGION_ID}-${znum} did not yield a healthy $name, trying the next zone..."
+    done
+    echo "❌ Error: VSI $name could not be created in any zone (tried ${REGION_ID}-{${order[*]}}). Exiting now."
+    exit 1
+}
+
 # Create Control Nodes
 for i in $(seq 1 $CONTROL_NODE_COUNT); do
     CONTROL_VSI_NAME="control-${i}"
-    ZONE="${REGION_ID}-$(($i % 3 + 1))"
-    SUBNET_NAME="${CLUSTER_NAME}-sn-$(($i % 3 + 1))"
+    ZONE_NUM=$(($i % 3 + 1))
     if [ "$CONTROL_NODE_COUNT" -eq 1 ]; then
        COMPUTE_NODE_COUNT=0
        CONTROL_VSI_NAME="sno"
     fi
-    create_vsi "$CLUSTER_NAME-$CONTROL_VSI_NAME" "$ZONE" "$CONTROL_PROFILE" "$SUBNET_NAME" "$IMAGE_NAME" "$VSI_SSH_KEYS" "$sg_name"
+    create_vsi_with_fallback "$CLUSTER_NAME-$CONTROL_VSI_NAME" "$ZONE_NUM" "$CONTROL_PROFILE" "$IMAGE_NAME" "$VSI_SSH_KEYS" "$sg_name"
 done
 
 # Create Compute Nodes
-if [ "$COMPUTE_NODE_COUNT" -gt 0 ]; then
+if [ "$COMPUTE_NODE_COUNT" -gt 0 ]; then
     for i in $(seq 1 $COMPUTE_NODE_COUNT); do
-        ZONE="${REGION_ID}-$(($i % 3 + 1))"
-        SUBNET_NAME="${CLUSTER_NAME}-sn-$(($i % 3 + 1))"
-        create_vsi "$CLUSTER_NAME-compute-$i" "$ZONE" "$COMPUTE_PROFILE" "$SUBNET_NAME" "$IMAGE_NAME" "$VSI_SSH_KEYS" "$sg_name"
+        ZONE_NUM=$(($i % 3 + 1))
+        create_vsi_with_fallback "$CLUSTER_NAME-compute-$i" "$ZONE_NUM" "$COMPUTE_PROFILE" "$IMAGE_NAME" "$VSI_SSH_KEYS" "$sg_name"
     done
 fi
 
 # Create Bastion
-create_vsi "$CLUSTER_NAME-bastion" "$REGION_ID-2" "$BASTION_PROFILE" "$CLUSTER_NAME-sn-2" "$IMAGE_NAME" "$VSI_SSH_KEYS" "$sg_name"
+create_vsi_with_fallback "$CLUSTER_NAME-bastion" "2" "$BASTION_PROFILE" "$IMAGE_NAME" "$VSI_SSH_KEYS" "$sg_name"
 BASTION_FIP=$(ibmcloud is floating-ip ${CLUSTER_NAME}-bastion-ip --output JSON | jq -r '.address')
 BASTION_RIP=$(ibmcloud is instance $CLUSTER_NAME-bastion --output JSON | jq -r '.network_interfaces[0].primary_ip.address')
 
diff --git a/scripts/5-generate-boot-artifacts.sh b/scripts/5-generate-boot-artifacts.sh
index 081ae33..50fa1f5 100755
--- a/scripts/5-generate-boot-artifacts.sh
+++ b/scripts/5-generate-boot-artifacts.sh
@@ -108,14 +108,13 @@ cp $HOME/$CLUSTER_NAME/agent-config.yaml $HOME/$CLUSTER_NAME/agent-config.yaml.o
 
 echo -e "\n✅ Install Config and Agent Config YAML files have been generated in the $HOME/$CLUSTER_NAME directory."
 
-oc registry login --to=/tmp/pull-secret.json
-jq -s '.[0].auths * .[1].auths | {auths: .}' /tmp/pull-secret.json $HOME/pull-secret > $HOME/secret.json
-
+# oc registry login --to=/tmp/pull-secret.json
+# jq -s '.[0].auths * .[1].auths | {auths: .}' /tmp/pull-secret.json $HOME/pull-secret > $HOME/secret.json
 
 # Extract the openshift installer
 if [ ! -f "$HOME/$CLUSTER_NAME/openshift-install" ]; then
   echo -e "\nExtracting the openshift installer ⏳..."
-  oc adm release extract -a $HOME/secret.json --command openshift-install $OCP_RELEASE_IMAGE --to=$HOME/$CLUSTER_NAME
+  oc adm release extract -a $PULL_SECRET_FILE --command openshift-install $OCP_RELEASE_IMAGE --to=$HOME/$CLUSTER_NAME
 else
   echo -e "\nOpenshift Installer already exists, Skipping the extraction."
 fi
@@ -127,9 +126,9 @@ if [ -d "$HOME/$CLUSTER_NAME/boot-artifacts" ] && [ "$(ls -A "$HOME/$CLUSTER_NAM
 else
   echo -e "\nGenerating the boot artifacts to boot OpenShift cluster nodes ⚙️ ..."
   export PATH="$HOME/.tmp/bin:$PATH"
-  file1=$(grep 'pullSecret:' $HOME/$CLUSTER_NAME/install-config.yaml | sed "s/.*pullSecret: '\(.*\)'/\1/")
-  file2=$(jq -s '.[0].auths + .[1].auths | {auths: .}' <(echo "$file1") /tmp/pull-secret.json)
-  sed -i "/pullSecret:/c\pullSecret: '$(echo $file2 | jq -c .)'" $HOME/$CLUSTER_NAME/install-config.yaml
+  #file1=$(grep 'pullSecret:' $HOME/$CLUSTER_NAME/install-config.yaml | sed "s/.*pullSecret: '\(.*\)'/\1/")
+  #file2=$(jq -s '.[0].auths + .[1].auths | {auths: .}' <(echo "$file1") /tmp/pull-secret.json)
+  #sed -i "/pullSecret:/c\pullSecret: '$(echo $file2 | jq -c .)'" $HOME/$CLUSTER_NAME/install-config.yaml
   $HOME/$CLUSTER_NAME/openshift-install agent create pxe-files --dir $HOME/$CLUSTER_NAME --log-level debug
   echo "Successfully generated the boot artifacts"
 fi
PATCH



#Navigate to clone directory
cd "ibmcloud-openshift-provisioning" || {
    echo "Failed to cd into ibmcloud-openshift-provisioning"
    exit 1
}



#export OCP_RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:4.20.0-ec.5-s390x"

VARS_FILE="cluster-vars"

sed -i "s/^CLUSTER_NAME=.*/CLUSTER_NAME=\"$CLUSTER_NAME\"/" "$VARS_FILE"
sed -i "s/^CLUSTER_ARCH=.*/CLUSTER_ARCH=\"$CLUSTER_ARCH\"/" "$VARS_FILE"
sed -i "s/^CLUSTER_VERSION=.*/CLUSTER_VERSION=\"$CLUSTER_VERSION\"/" "$VARS_FILE"
sed -i "s/^CONTROL_NODE_COUNT=.*/CONTROL_NODE_COUNT=$CONTROL_NODE_COUNT/" "$VARS_FILE"
sed -i "s/^COMPUTE_NODE_COUNT=.*/COMPUTE_NODE_COUNT=$COMPUTE_NODE_COUNT/" "$VARS_FILE"
sed -i "s|^PULL_SECRET_FILE=.*|PULL_SECRET_FILE=\"$PULL_SECRET_FILE\"|" "$VARS_FILE"
sed -i "s/^REGION=.*/REGION=\"$REGION\"/" "$VARS_FILE"
sed -i "s/^RESOURCE_GROUP=.*/RESOURCE_GROUP=\"$RESOURCE_GROUP\"/" "$VARS_FILE"
set +x
sed -i "s/^IC_API_KEY=.*/IC_API_KEY=\"$IC_API_KEY\"/" "$VARS_FILE"
set -x
sed -i "s/^IC_CLI_VERSION=.*/IC_CLI_VERSION=\"$IC_CLI_VERSION\"/" "$VARS_FILE"
sed -i "s|^OCP_RELEASE_IMAGE=.*|OCP_RELEASE_IMAGE=\"$OCP_RELEASE_IMAGE\"|" "$VARS_FILE"
sed -i "s/^CONTROL_NODE_PROFILE=.*/CONTROL_NODE_PROFILE=\"$CONTROL_NODE_PROFILE\"/" "$VARS_FILE"
sed -i "s/^COMPUTE_NODE_PROFILE=.*/COMPUTE_NODE_PROFILE=\"$COMPUTE_NODE_PROFILE\"/" "$VARS_FILE"
sed -i "s/^VSI_IMAGE_NAME=.*/VSI_IMAGE_NAME=\"$VSI_IMAGE_NAME\"/" "$VARS_FILE"
sed -i "s/^ENABLE_NESTED_VIRT=.*/ENABLE_NESTED_VIRT=\"$ENABLE_NESTED_VIRT\"/" "$VARS_FILE"
sed -i "s/^CREATE_STORAGE_CLASS=.*/CREATE_STORAGE_CLASS=\"$CREATE_STORAGE_CLASS\"/" "$VARS_FILE"

# Run the create-cluster.sh script to create the OCP cluster in IBM cloud VPC
if [[ -x ./create-cluster.sh ]]; then
    ./create-cluster.sh
else
    echo "create-cluster.sh not found or not executable"
    exit 1
fi


export mgmt_cluster_key=$CLUSTER_NAME
# Saving the cluster name and kubeconfig to SHARED_DIR
echo "$mgmt_cluster_key" >> "$SHARED_DIR/mgmt_cluster_name"

echo "Printing the management cluster name"
cat "$SHARED_DIR/mgmt_cluster_name"

echo "Copying kubeconfig into SHARED_DIR"
cp "$HOME/$CLUSTER_NAME/auth/kubeconfig" "$SHARED_DIR/kubeconfig"
echo "Kubeconfig copied into SHARED_DIR"

#Saving node keys to SHARED_DIR
cp "$HOME/$CLUSTER_NAME/.ssh/$CLUSTER_NAME-key" "$SHARED_DIR/$CLUSTER_NAME-key"
