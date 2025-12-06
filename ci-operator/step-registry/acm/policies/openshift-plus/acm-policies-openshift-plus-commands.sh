#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# cd to writeable directory
cd /tmp/

git clone https://github.com/tanfengshuang/policy-collection.git

sleep 60

cd policy-collection/deploy/ 
echo 'y' | ./deploy.sh -p policygenerator/policy-sets/stable/openshift-plus -n policies -u https://github.com/tanfengshuang/policy-collection.git -a openshift-plus

sleep 120

# wait for policies to be compliant
RETRIES=40
for try in $(seq "${RETRIES}"); do
  results=$(oc get policies -n policies)
  notready=$(echo "$results" | grep -E 'NonCompliant|Pending' || true)
  if [ "$notready" == "" ]; then
    echo "OPP policyset is applied and compliant"
    break
  else
    if [ $try == $RETRIES ]; then
      if [ "$IGNORE_SECONDARY_POLICIES" == "true" ]; then
        CANDIDATES=$(echo "$notready" | grep -v policy-acs | grep -v policy-advanced-managed-cluster-status | grep -v policy-hub-quay-bridge | grep -v policy-quay-status || true)
        if [ -z "$CANDIDATES" ]; then
          echo "Warning: Proceeding with OPP QE tests with some policy failures"
          exit 0
        else
          echo "Error policies failed to become compliant in allotted time, even considering the ignore list."
          exit 1
        fi
      else
        echo "Error policies failed to become compliant in allotted time."
        exit 1
      fi
    fi
    echo "Try ${try}/${RETRIES}: Policies are not compliant. Checking again in 30 seconds"
    sleep 30
  fi
done

set +e
# 1. NooBaa endpoint pod 稳定性
echo "NooBaa endpoint pod stable"
oc get pod -n openshift-storage -l noobaa-s3=noobaa

echo "check pod restart:"
oc get pod -n openshift-storage -l noobaa-s3=noobaa -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}'

#  2. CPU 使用情况
echo "CPU usage"
oc adm top pod -n openshift-storage | grep endpoint

#  3. BackingStore 状态
echo "BackingStore status"
  oc get backingstore -n openshift-storage
  oc describe backingstore noobaa-pv-backing-store -n openshift-storage

# 4. 测试 S3 endpoint
echo "test S3 endpoint"
  oc get route -n openshift-storage s3
  curl -k https://"$(oc get route s3 -n openshift-storage -o jsonpath='{.spec.host}')"





echo
echo
echo

echo 检查 StorageCluster 详细状态
  oc get storagecluster ocs-storagecluster -n openshift-storage -o yaml

echo 检查 StorageCluster 是否 Ready
  oc get storagecluster ocs-storagecluster -n openshift-storage -o jsonpath='{.status.phase}'
  # 期望输出: Ready

echo 查看 StorageCluster 的所有 conditions
  oc get storagecluster ocs-storagecluster -n openshift-storage -o jsonpath='{.status.conditions[*].type}'

echo  2.2 验证 NooBaa 核心组件（重点！）

echo 🔥 关键检查: noobaa-db-pg deployment 是否存在
  oc get deployment noobaa-db-pg -n openshift-storage
  # 如果返回 "NotFound"，说明问题还在！

echo 检查 NooBaa 所有 deployments
  oc get deployments -n openshift-storage | grep noobaa

  # 期望看到:
  # noobaa-core
  # noobaa-db-pg       ← 这个最关键！
  # noobaa-endpoint
  # noobaa-operator

echo 检查 NooBaa pods 状态
  oc get pods -n openshift-storage | grep noobaa

echo 检查 noobaa-db-pg pod 日志（如果存在）
  oc logs -n openshift-storage deployment/noobaa-db-pg --tail=50

echo   2.3 验证 NooBaa 实例状态

echo 检查 NooBaa CR 状态
  oc get noobaa noobaa -n openshift-storage -o yaml

echo 检查 NooBaa phase
  oc get noobaa noobaa -n openshift-storage -o jsonpath='{.status.phase}'
echo 期望输出: Ready

echo 检查 NooBaa 是否有 manualDefaultBackingStore 设置
  oc get noobaa noobaa -n openshift-storage -o jsonpath='{.spec.manualDefaultBackingStore}'
echo 如果输出 "true"，说明我们的修改还没生效
echo 如果输出为空或 "false"，说明修改正确

echo  2.4 验证 BackingStore 状态

echo 列出所有 BackingStores
  oc get backingstore -n openshift-storage

echo 检查 noobaa-pv-backing-store 状态
  oc get backingstore noobaa-pv-backing-store -n openshift-storage -o jsonpath='{.status.phase}'
echo 期望输出: Ready

echo 查看详细信息
  oc get backingstore noobaa-pv-backing-store -n openshift-storage -o yaml

echo 检查 PVCs（应该有 3 个，对应 numVolumes: 3）
  oc get pvc -n openshift-storage | grep noobaa-pv-backing-store

echo 2.5 验证 BucketClass 状态

echo 检查 BucketClass
  oc get bucketclass -n openshift-storage

echo 检查 noobaa-default-bucket-class 状态
  oc get bucketclass noobaa-default-bucket-class -n openshift-storage -o jsonpath='{.status.phase}'
echo 期望输出: Ready

echo验证 BucketClass 使用的 BackingStore
  oc get bucketclass noobaa-default-bucket-class -n openshift-storage -o jsonpath='{.spec.placementPolicy.tiers[0].backingStores[*]}'
echo 期望输出: noobaa-pv-backing-store

echo 查看详细配置
  oc get bucketclass noobaa-default-bucket-class -n openshift-storage -o yaml


echo 检查 NooBaa 服务端点

echo 获取 NooBaa S3 endpoint
  oc get route s3 -n openshift-storage -o jsonpath='{.spec.host}'

echo 检查 NooBaa 管理端点
  oc get route noobaa-mgmt -n openshift-storage -o jsonpath='{.spec.host}'

echo  检查 NooBaa services
  oc get svc -n openshift-storage | grep noobaa


echo 检查 Quay 的 ObjectBucketClaim
  oc get obc -n local-quay

echo 检查 Quay datastore OBC 详细信息
  oc get obc registry-quay-datastore -n local-quay -o yaml

echo 检查对应的 ObjectBucket 状态
  oc get objectbucket obc-local-quay-registry-quay-datastore -o jsonpath='{.status.phase}'
echo 期望输出: Bound

echo 检查 Quay 存储的 secret 和 configmap
  oc get secret obc-local-quay-registry-quay-datastore -n local-quay
  oc get configmap obc-local-quay-registry-quay-datastore -n local-quay

set -e



